"""Optional integration check: python3 tests/heading_raster_test.py (Pango/Cairo)."""
import base64
import importlib.util
import io
import math
from pathlib import Path
import sys

spec = importlib.util.spec_from_file_location("heading_renderer", Path(__file__).resolve().parents[1] / "scripts/render-heading.py")
renderer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(renderer)
ratios = (2, 1.75, 1.5, 1.4, 1.25, 7 / 6)
request = dict(font="Noto Sans Mono,Noto Sans Mono CJK TC", font_pixels="auto",
               entries=[dict(text="日本中文共同文字", ratio=r, rows=2, max_cols=35,
                             fg=0xffffff, bg=0, bold=True) for r in ratios])
for width, height in ((8, 16), (9, 20), (10, 22), (19, 44), (28, 64)):
    request.update(cell_width=width, cell_height=height)
    outputs = renderer.render(request)
    base = outputs[0]["font_pixels"] / ratios[0]
    assert len({o["font_pixels"] for o in outputs}) == 6
    for output, ratio in zip(outputs, ratios):
        assert math.isclose(output["font_pixels"] / ratio, base)
        assert len(output["lines"]) == 1, "Han heading fits measured width; no premature wrap"
        line = output["lines"][0]
        assert "data" in line, (width, height, line)
        assert len(line["columns"]) == line["cols"] <= 35
        assert {b for b in line["columns"] if b is not False} == set(range(0, 24, 3))
request.update(cell_width=19, cell_height=44)
entry = request["entries"][0]
request["entries"] = [entry]
entry.update(text="FIRST SECOND", ratio=1.75)
line = renderer.render(request)[0]["lines"][0]
assert line["columns"][7] < 5 and line["columns"][12] >= 6, "visible links have shaped UTF-8 targets"
entry.update(text="Ae\u0301漢")
line = renderer.render(request)[0]["lines"][0]
assert {b for b in line["columns"] if b is not False} == {0, 1, 4}, "combining marks stay with their grapheme"
entry.update(text="日本中文共同文字 long heading words " * 4, max_cols=20)
lines = renderer.render(request)[0]["lines"]
assert len(lines) > 1
assert "".join(line["text"] for line in lines) == entry["text"], "wrapping loses no text or spaces"
raw = entry["text"].encode()
for line in lines:
    assert raw[line["start"]:line["end"]].decode() == line["text"]
    assert "data" in line and line["cols"] <= 20
    assert all(b is False or b < len(line["text"].encode()) for b in line["columns"])

# Decorations change actual pixels. Nested spans retain both their color pair
# and independent emphasis; light themes must not get a dark full-line canvas.
entry.update(text="日本中文共同文字", max_cols=35)
for background in (0x14161b, 0xffffff):
    entry.update(bg=background, fg=0x808080, styles=[])
    plain = renderer.render(request)[0]["lines"][0]["data"]
    for style in (dict(strikethrough=True), dict(underline=True), dict(italic=True), dict(bold=False)):
        entry["styles"] = [dict(start=12, end=18, **style)]
        assert renderer.render(request)[0]["lines"][0]["data"] != plain, style
    entry["styles"] = [dict(start=12, end=18, fg=0xffec80, bg=0x3b3600), dict(start=12, end=18, underline=True)]
    line = renderer.render(request)[0]["lines"][0]
    surface = renderer.cairo.ImageSurface.create_from_png(io.BytesIO(base64.b64decode(line["data"])))
    pixels = bytes(surface.get_data())
    assert (0xff3b3600).to_bytes(4, sys.byteorder) in pixels
    assert pixels[:4] == (0xff000000 | background).to_bytes(4, sys.byteorder)
entry.pop("bg")
line = renderer.render(request)[0]["lines"][0]
surface = renderer.cairo.ImageSurface.create_from_png(io.BytesIO(base64.b64decode(line["data"])))
pixels = bytes(surface.get_data())
assert line["transparent"] and pixels[:4] == bytes(4), "unset backgrounds retain PNG alpha"
assert (0xff3b3600).to_bytes(4, sys.byteorder) in pixels, "explicit inline backgrounds remain opaque"
request["font_pixels"] = 100
assert "fallback" in renderer.render(request)[0]["lines"][0], "oversize fonts retain operable text"
print("heading raster: six sizes, measured wrapping, UTF-8 targets and dark/light styles OK")
