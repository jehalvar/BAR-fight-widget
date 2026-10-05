"""Render the actual Lua timing panel using explicitly fictional test data."""
import argparse
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

from test_widget import WidgetTests, profile, timing_profile, quick_catalogue


def render(unit_images=None, output=None):
    case = WidgetTests('runTest')
    case.setUp()
    case.add_player(1, 'Example player', '100')
    for index in range(2, 17):
        case.add_player(index, f'Player {index:02}', str(index * 100), 0 if index <= 8 else 1)
    case.start()
    histories = []
    for index in range(1, 17):
        history = profile(str(index * 100))
        position = history['positions'][0]
        history['positions'] = [dict(position, spot='P2' if index % 2 else 'P8', games=21, traits=[]),
                                dict(position, spot='P3', games=9, traits=[])]
        history['period'] = dict(start_date='2026-09-06', end_date='2026-10-05')
        histories.append(history)
    case.respond(histories)
    case.call('ViewResize', 1280, 900)
    case.call('TextCommand', 'barfight timing')
    value = timing_profile()
    value['name'] = 'Example player'
    case.timing_respond([value], units=quick_catalogue())
    # Optional local unit pictures for visual QA. Game artwork is not bundled
    # with the open-source client or required to execute this renderer.
    icons = {}
    if unit_images:
        paths = sorted(p for p in Path(unit_images).iterdir() if p.suffix.lower() in ('.png', '.webp', '.dds'))
        definitions = {}
        for index, path in enumerate(paths, 1):
            definitions[path.stem] = case.lua.table_from(dict(id=index))
            icons['#' + str(index)] = path
        case.globals.UnitDefNames = case.lua.table_from(definitions)
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
    calls, colour, texture = [], [255, 255, 255, 255], [None]
    def color(r, g, b, a):
        colour[:] = [round(c * 255) for c in (r, g, b, a)]
    def rect(x1, y1, x2, y2):
        calls.append(('rect', (x1 - 400, 840 - y2, x2 - 400, 840 - y1), tuple(colour)))
    def text(value, x, y, size, options):
        calls.append(('text', (value, x - 400, 840 - y, size, options), tuple(colour)))
    def bind_texture(value):
        texture[0] = icons.get(value)
        return texture[0] is not None
    def tex_rect(x1, y1, x2, y2):
        assert texture[0] is not None
        calls.append(('image', (x1 - 400, 840 - y2, x2 - 400, 840 - y1), texture[0]))
    case.globals.previewColor, case.globals.previewRect, case.globals.previewText = color, rect, text
    case.globals.previewTexture, case.globals.previewTexRect = bind_texture, tex_rect
    case.globals.previewWidth = lambda value: font(100).getlength(value) / (100 * scale)
    case.lua.execute('''
        local originalText = gl.Text
        gl.Color = function(...) previewColor(...) end
        gl.Rect = function(...) previewRect(...) end
        gl.Text = function(...) originalText(...); previewText(...) end
        gl.GetTextWidth = function(value) return previewWidth(value) end
        gl.Texture = function(value) return previewTexture(value) end
        gl.TexRect = function(...) previewTexRect(...) end
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
        elif kind == 'image':
            x1, y1, x2, y2 = (round(v * scale) for v in values)
            icon = Image.open(rgba).convert('RGBA').resize((x2 - x1, y2 - y1), Image.Resampling.LANCZOS)
            canvas.paste(icon, (x1, y1), icon)
        else:
            value, x, y, size, options = values
            anchor = 'rs' if 'r' in options else 'ms' if 'c' in options else 'ls'
            drawing.text((round(x * scale), round(y * scale)), value, font=font(size), fill=rgba, anchor=anchor)
    output = Path(output) if output else Path(__file__).resolve().parents[1] / 'preview' / 'timings-panel-example.png'
    output.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(output, optimize=True)
    print(output)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--unit-images', type=Path, help='Optional local BAR unit-picture directory; artwork is not bundled.')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    render(args.unit_images, args.output)
