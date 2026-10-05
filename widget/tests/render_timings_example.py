"""Render the actual Lua timing panel using explicitly fictional test data."""
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

from test_widget import WidgetTests, timing_profile, quick_catalogue


def render():
    case = WidgetTests('runTest')
    case.setUp()
    case.add_player(1, 'Example player', '100')
    for index in range(2, 17):
        case.add_player(index, f'Player {index:02}', str(index * 100), 0 if index <= 8 else 1)
    case.start()
    case.call('ViewResize', 1280, 900)
    case.call('TextCommand', 'barfight timing')
    value = timing_profile()
    value['name'] = 'Example player'
    case.timing_respond([value], units=quick_catalogue())
    scale, width, height = 2, 900, 720
    font_path = next((p for p in (Path('C:/Windows/Fonts/segoeui.ttf'),
        Path('/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf')) if p.is_file()), None)
    if font_path is None:
        raise RuntimeError('Segoe UI or DejaVu Sans is required.')
    fonts = {}
    def font(size):
        pixels = round(size * scale)
        if pixels not in fonts:
            fonts[pixels] = ImageFont.truetype(str(font_path), pixels)
        return fonts[pixels]
    calls, colour = [], [255, 255, 255, 255]
    def color(r, g, b, a):
        colour[:] = [round(c * 255) for c in (r, g, b, a)]
    def rect(x1, y1, x2, y2):
        calls.append(('rect', (x1 - 400, 840 - y2, x2 - 400, 840 - y1), tuple(colour)))
    def text(value, x, y, size, options):
        calls.append(('text', (value, x - 400, 840 - y, size, options), tuple(colour)))
    case.globals.previewColor, case.globals.previewRect, case.globals.previewText = color, rect, text
    case.globals.previewWidth = lambda value: font(100).getlength(value) / (100 * scale)
    case.lua.execute('''
        local originalText = gl.Text
        gl.Color = function(...) previewColor(...) end
        gl.Rect = function(...) previewRect(...) end
        gl.Text = function(...) originalText(...); previewText(...) end
        gl.GetTextWidth = function(value) return previewWidth(value) end
    ''')
    drawn = case.draw()
    for label in ('Build timings', 'T2 constructors', 'Tech', '4:42', 'Copy timing'):
        assert any(label in item for item in drawn), label
    canvas = Image.new('RGB', (width * scale, height * scale), '#09131c')
    drawing = ImageDraw.Draw(canvas, 'RGBA')
    drawing.text((40 * scale, 25 * scale), 'ILLUSTRATIVE EXAMPLE', font=font(11), fill='#85ebd3')
    drawing.text((40 * scale, 43 * scale), 'Fictional players and timings | Actual widget layout', font=font(12), fill='#aec3ce')
    for kind, values, rgba in calls:
        if kind == 'rect':
            x1, y1, x2, y2 = values
            assert 0 <= x1 <= x2 <= width and 0 <= y1 <= y2 <= height, values
            drawing.rectangle(tuple(round(v * scale) for v in values), fill=rgba)
        else:
            value, x, y, size, options = values
            anchor = 'rs' if 'r' in options else 'ms' if 'c' in options else 'ls'
            drawing.text((round(x * scale), round(y * scale)), value, font=font(size), fill=rgba, anchor=anchor)
    output = Path(__file__).resolve().parents[1] / 'preview' / 'timings-panel-example.png'
    output.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(output, optimize=True)
    print(output)


if __name__ == '__main__':
    render()
