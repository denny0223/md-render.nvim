"""Shape, wrap and rasterize headings with one Pango layout. JSON in/out."""
import base64
import io
import json
import math
import sys

import cairo
import gi

gi.require_version("Pango", "1.0")
gi.require_version("PangoCairo", "1.0")
from gi.repository import Pango, PangoCairo


def rgb(value):
    return tuple((value >> shift & 255) / 255 for shift in (16, 8, 0))


def attributes_for(styles):
    attributes = Pango.AttrList()
    for span in styles:
        values = []
        for key, factory in (("fg", Pango.attr_foreground_new), ("bg", Pango.attr_background_new)):
            if key in span:
                values.append(factory(*(round(c * 65535) for c in rgb(span[key]))))
        if "sp" in span:
            color = tuple(round(c * 65535) for c in rgb(span["sp"]))
            values.extend((Pango.attr_underline_color_new(*color), Pango.attr_strikethrough_color_new(*color)))
        for key, factory in (("bold", lambda b: Pango.attr_weight_new(Pango.Weight.BOLD if b else Pango.Weight.NORMAL)),
                             ("italic", lambda b: Pango.attr_style_new(Pango.Style.ITALIC if b else Pango.Style.NORMAL)),
                             ("strikethrough", Pango.attr_strikethrough_new),
                             ("underline", lambda b: Pango.attr_underline_new(Pango.Underline.SINGLE if b else Pango.Underline.NONE))):
            if key in span:
                values.append(factory(span[key]))
        for attribute in values:
            attribute.start_index, attribute.end_index = span["start"], span["end"]
            attributes.change(attribute)
    return attributes


def render(request):
    layout = PangoCairo.create_layout(cairo.Context(cairo.RecordingSurface(cairo.CONTENT_COLOR_ALPHA, None)))
    font = Pango.FontDescription()
    font.set_family(request["font"])
    base_pixels = request["font_pixels"]
    if base_pixels == "auto":
        font.set_absolute_size(32 * Pango.SCALE)
        metrics = layout.get_context().get_metrics(font, Pango.Language.from_string("en"))
        base_pixels = 32 * Pango.SCALE * min(
            request["cell_width"] / metrics.get_approximate_char_width(),
            request["cell_height"] / max(metrics.get_height(), metrics.get_ascent() + metrics.get_descent()),
        )
    results = []
    for index, entry in enumerate(request["entries"]):
        font.set_weight(Pango.Weight.BOLD if entry["bold"] else Pango.Weight.NORMAL)
        pixels = base_pixels * entry["ratio"]
        font.set_absolute_size(round(pixels * Pango.SCALE))
        layout.set_font_description(font)
        layout.set_text(entry["text"], -1)
        layout.set_attributes(attributes_for(entry.get("styles", [])))
        layout.set_width(entry["max_cols"] * request["cell_width"] * Pango.SCALE)
        layout.set_wrap(Pango.WrapMode.WORD_CHAR)
        text = entry["text"].encode("utf-8")
        result = {"index": index + 1, "font_pixels": pixels, "lines": []}
        for line in layout.get_lines_readonly():
            ink, logical = line.get_pixel_extents()
            x = max(0, -ink.x)
            width = max(logical.width, ink.x + ink.width) + x
            cols = max(1, math.ceil(width / request["cell_width"]))
            height = request["cell_height"] * entry["rows"]
            output = {"start": line.start_index, "end": line.start_index + line.length,
                      "text": text[line.start_index:line.start_index + line.length].decode("utf-8"), "cols": cols}
            if layout.get_unknown_glyphs_count():
                output["fallback"] = "missing glyph"
            elif cols > entry["max_cols"]:
                output["fallback"] = "glyph exceeds available width"
            elif ink.height > height:
                output["fallback"] = "glyph exceeds reserved height"
            else:
                columns = []
                for column in range(cols):
                    inside, byte, _ = line.x_to_index(round(((column + 0.5) * request["cell_width"] - x) * Pango.SCALE))
                    columns.append(byte - line.start_index if inside else False)
                surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, cols * request["cell_width"], height)
                painter = cairo.Context(surface)
                # An unspecified Neovim background belongs to the terminal.
                if entry.get("bg") is not None:
                    painter.set_source_rgb(*rgb(entry["bg"]))
                    painter.paint()
                painter.set_source_rgb(*rgb(entry["fg"]))
                painter.move_to(x, (height - ink.height) / 2 - ink.y)
                PangoCairo.show_layout_line(painter, line)
                png = io.BytesIO()
                surface.write_to_png(png)
                output.update(data=base64.b64encode(png.getvalue()).decode("ascii"),
                              width=surface.get_width(), height=height, columns=columns,
                              transparent=entry.get("bg") is None)
            result["lines"].append(output)
        results.append(result)
    return results


if __name__ == "__main__":
    request = json.load(sys.stdin)
    outputs = [render(r)[0] for r in request["requests"]] if "requests" in request else render(request)
    print(json.dumps(outputs, ensure_ascii=False))
