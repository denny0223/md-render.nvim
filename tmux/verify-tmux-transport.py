"""Isolated real Kitty/tmux transport, pane-offset and lifecycle experiments."""
import json
import os
from pathlib import Path
import shlex
import signal
import subprocess
import sys
import tempfile
import time
from PIL import Image

ROOT = Path(__file__).resolve().parent
OUT = ROOT/'tmux-evidence'
OUT.mkdir(exist_ok=True)
PNG = ROOT/'heading.png'
env = dict(os.environ, DISPLAY=os.environ.get('DISPLAY', ':0'))
for key in ('TMUX', 'TMUX_PANE', 'TERM_PROGRAM', 'TERM_PROGRAM_VERSION'):
    env.pop(key, None)


def run(args):
    return subprocess.check_output(args, env=env, text=True, timeout=10)


with tempfile.TemporaryDirectory(prefix='md-heading-tmux-probe-') as directory:
    runtime = Path(directory)
    config = runtime/'tmux.conf'
    config.write_text('set -g default-terminal tmux-256color\nset -g allow-passthrough on\nset -g status 2\nset -g status-position top\nset -g status-interval 0\nset -g status-format[0] "tmux transport probe | window: #{window_name}"\nset -g status-format[1] "active pane: #{pane_index}"\n')
    socket = str(runtime/'tmux.sock')
    terminal = 'unix:'+str(runtime/'kitty.sock')

    def tmux(*args):
        return run(['tmux', '-S', socket, *args])

    def kitty(*args):
        return run(['kitty', '@', '--to', terminal, *args])

    seq = 0
    evidence = {}

    def request(name, **command):
        global seq
        seq += 1
        (runtime/'request.json').write_text(json.dumps(dict(seq=seq, **command)))
        deadline = time.monotonic()+6
        while True:
            try:
                response = json.loads((runtime/'response.json').read_text())
                if response['seq'] == seq:
                    evidence[name] = response
                    print(name+': '+json.dumps(response), flush=True)
                    return response
            except (FileNotFoundError, json.JSONDecodeError):
                pass
            assert time.monotonic() < deadline, name
            time.sleep(.05)

    def capture(name):
        time.sleep(2.5)
        ansi = kitty('get-text', '--ansi')
        (OUT/(name+'.ansi')).write_text(ansi)
        expected_png = name not in ('after-clear', 'inactive-probe-receiver', 'placeholders-other-window')
        deadline = time.monotonic()+8
        while True:
            run(['magick', 'import', '-window', window, str(OUT/(name+'.png'))])
            with Image.open(OUT/(name+'.png')).convert('RGB') as screenshot:
                ink = sum(b > 120 and g > 130 and r < 190 and b > r+40 for r,g,b in screenshot.get_flattened_data())
            if (ink > 50) == expected_png:
                break
            assert time.monotonic() < deadline, (name, ink, expected_png)
            time.sleep(.15)
        evidence[name] = {'osc66_present':'\x1b]66;' in ansi, 'image_ink_pixels':ink}

    run(['tmux', '-S', socket, '-f', str(config), 'new-session', '-d', '-s', 'probe', '-x', '100', '-y', '36', 'sleep 3600'])
    args = ['kitty', '--config', 'NONE', '--title', 'md-render isolated tmux feasibility',
            '-o', 'allow_remote_control=yes', '-o', 'confirm_os_window_close=0',
            '-o', 'remember_window_size=no', '-o', 'initial_window_width=100c',
            '-o', 'initial_window_height=36c', '-o', 'font_size=10',
            '-o', 'linux_display_server=x11', '--listen-on', terminal,
            'tmux', '-S', socket, 'attach-session', '-t', 'probe']
    with (OUT/'kitty.log').open('w') as log:
        process = subprocess.Popen(args, env=env, stdout=log, stderr=log, start_new_session=True)
        try:
            deadline = time.monotonic()+20
            while not (runtime/'kitty.sock').exists():
                assert time.monotonic() < deadline and process.poll() is None
                time.sleep(.05)
            window = str(json.loads(kitty('ls'))[0]['platform_window_id'])
            tmux('split-window', '-h', '-t', 'probe:0.0', 'sleep 3600')
            child = shlex.join([sys.executable, str(ROOT/'tmux-probe-child.py'), directory, str(PNG)])
            pane = tmux('split-window', '-v', '-t', 'probe:0.1', '-P', '-F', '#{pane_id}', child).strip()
            while not (runtime/'child-ready').exists():
                assert time.monotonic() < deadline
                time.sleep(.05)
            active = request('active-probe', op='probe')
            assert 'OK' in active['png_reply'], active
            request('local-coordinates', op='paint', position='local')
            capture('local-coordinates-screen')
            request('pane-coordinates', op='paint', position='pane')
            capture('pane-coordinates-screen')
            tmux('refresh-client')
            capture('after-tmux-redraw')
            request('repaint', op='paint', position='pane')
            tmux('new-window', '-n', 'other', 'sleep 3600')
            capture('other-window')
            tmux('select-window', '-t', 'probe:0')
            request('clear', op='clear')
            capture('after-clear')
            assert not evidence['after-clear']['osc66_present']
            tmux('set-option', '-p', '-t', pane, 'allow-passthrough', 'off')
            blocked = request('passthrough-off-probe', op='probe')
            assert 'OK' not in blocked['png_reply'], blocked
            tmux('set-option', '-p', '-t', pane, 'allow-passthrough', 'on')
            tmux('select-pane', '-t', 'probe:0.0')
            inactive = request('inactive-pane-probe', op='probe')
            capture('inactive-probe-receiver')
            evidence['inactive-replies-in-active-pane'] = tmux('capture-pane', '-p', '-t', 'probe:0.0')
            assert 'i=42421;OK' in evidence['inactive-replies-in-active-pane']
            assert 'OK' not in inactive['png_reply']
            tmux('select-pane', '-t', pane)
            recovered = request('active-again-probe', op='probe')
            assert 'OK' in recovered['png_reply'], recovered
            request('placeholder-upload', op='paint', position='pane')
            request('placeholder-placement', op='placeholders')
            capture('unicode-placeholders')
            tmux('refresh-client')
            capture('placeholders-after-redraw')
            tmux('new-window', '-n', 'placeholder-other', 'sleep 3600')
            capture('placeholders-other-window')
            tmux('select-window', '-t', 'probe:0')
            capture('placeholders-return')
            evidence['versions'] = {'kitty':run(['kitty','--version']).strip(), 'tmux':run(['tmux','-V']).strip()}
        finally:
            (OUT/'results.json').write_text(json.dumps(evidence, ensure_ascii=False, indent=2)+'\n')
            subprocess.run(['tmux','-S',socket,'kill-server'], env=env, capture_output=True)
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                process.wait(timeout=5)
