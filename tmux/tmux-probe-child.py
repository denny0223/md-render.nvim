"""Raw terminal probe, deliberately without Neovim or md-render lifecycle code."""
import base64
import json
import os
from pathlib import Path
import select
import subprocess
import sys
import time
import tty

runtime, png = Path(sys.argv[1]), Path(sys.argv[2])
tty.setraw(0)
esc = b'\x1b'
image_id = 42422
last_position = None


def send(data, wrap=True):
    if wrap:
        data = esc + b'Ptmux;' + data.replace(esc, esc + esc) + esc + b'\\'
    os.write(1, data)


def response(expected):
    result = b''
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline:
        if select.select([0], [], [], .05)[0]:
            result += os.read(0, 65536)
            if expected in result and result.endswith(esc+b'\\'):
                break
    return result.decode('utf-8', 'backslashreplace')


def geometry():
    fields = '#{pane_left}|#{pane_top}|#{pane_width}|#{pane_height}|#{status}|#{status-position}|#{client_termname}'
    values = subprocess.check_output(['tmux', 'display-message', '-p', '-t', os.environ['TMUX_PANE'], fields], text=True).strip().split('|')
    return dict(zip(('left', 'top', 'width', 'height', 'status', 'status_position', 'terminal'), values))


def clear(keep_image=False):
    global last_position
    send(esc + f'_Ga=d,d={"i" if keep_image else "I"},i={image_id},q=2'.encode() + esc + b'\\')
    if last_position:
        row, col = last_position
        send(esc+b'7'+f'\x1b[{row};{col}H\x1b[16X\x1b[{row+1};{col}H\x1b[16X'.encode()+esc+b'8')
    last_position = None


send(esc+b'[2J'+esc+b'[H'+b'Target: bottom-right pane'+esc+b'[3;3H'+b' '*18+esc+b'[8;3H'+b' '*18, False)
(runtime/'child-ready').touch()
seen = 0
while True:
    request = runtime/'request.json'
    if not request.exists():
        time.sleep(.05)
        continue
    try:
        command = json.loads(request.read_text())
    except json.JSONDecodeError:
        continue
    if command['seq'] == seen:
        time.sleep(.05)
        continue
    seen = command['seq']
    result = {'seq': seen, 'command': command, 'geometry': geometry()}
    if command['op'] == 'probe':
        send(esc+b'[>q')
        result['version_reply'] = response(b'kitty(')
        tiny = b'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII='
        send(esc+b'_Ga=q,t=d,f=100,i=42421;'+tiny+esc+b'\\')
        result['png_reply'] = response(b'i=42421;OK')
    elif command['op'] == 'paint':
        clear()
        geo = result['geometry']
        row, col = 3, 3
        if command['position'] == 'pane':
            row += int(geo['top']) + (int(geo['status']) if geo['status_position'] == 'top' else 0)
            col += int(geo['left'])
        send(esc+b'7'+f'\x1b[{row};{col}H'.encode()+esc+b']66;s=2:n=7:d=8;NATIVE'+esc+b'\\'+esc+b'8')
        last_position = row, col
        data = base64.b64encode(png.read_bytes())
        for start in range(0, len(data), 4096):
            params = f'a=t,t=d,f=100,i={image_id},q=0,' if start == 0 else ''
            params += 'm='+str(int(start+4096 < len(data)))
            send(esc+b'_G'+params.encode()+b';'+data[start:start+4096]+esc+b'\\')
        result['upload_reply'] = response(b'i=42422;OK')
        send(esc+b'7'+f'\x1b[{row+5};{col}H'.encode()+esc+f'_Ga=p,i={image_id},c=14,r=2,C=1,q=2'.encode()+esc+b'\\'+esc+b'8')
        result['outer_native_cell'] = {'row':row, 'col':col}
    elif command['op'] == 'placeholders':
        clear(keep_image=True)
        send(esc+f'_Ga=p,U=1,i={image_id},c=14,r=2,q=2'.encode()+esc+b'\\')
        color = f'\x1b[38;2;{image_id>>16};{(image_id>>8)&255};{image_id&255}m'
        for row, diacritic in enumerate(('\u0305', '\u030d')):
            text = '\U0010eeee'+diacritic+'\u0305'+'\U0010eeee'*13
            send((f'\x1b[{8+row};3H'+color+text+'\x1b[0m').encode(), False)
    elif command['op'] == 'clear':
        clear()
    (runtime/'response.json').write_text(json.dumps(result))
