#!/usr/bin/env python3
"""Generates rive/scene.rml: the chrome (title bar, transport, footer, popovers)
and the view-model contract (docs/spec.md §10, §11).

The chrome follows the "compressed monochrome" design: neutral surfaces, 24 px
controls, condensed labels (Barlow Semi Condensed) and Iosevka numerals. The
editor grid itself is drawn by the AnimaScript layout (rive/src/editor).

Run from the repository root:  python3 tools/gen_scene.py
"""
import os

OUT = os.path.join(os.path.dirname(__file__), "..", "rive", "scene.rml")

# --- Palette (equal RGB channels only) ------------------------------------
CANVAS = "FF000000"
BAR = "FF0A0A0A"          # title bar, transport, headers, footer
CONTROL = "FF151515"      # default control
SELECTED = "FF222222"     # hover / selected
DIVIDER = "FF303030"      # subtle structural divider
EDGE = "FF666666"         # essential control boundary
WHITE = "FFFFFFFF"
SECONDARY = "FFA0A0A0"
SUBDUED = "FF808080"

FONT_MONO, FONT_MONO_BOLD, FONT_UI, FONT_UI_BOLD = "0:90", "0:91", "0:92", "0:93"

_next = [20000]


def nid():
    _next[0] += 1
    return f"0:{_next[0]}"


# --- View models -------------------------------------------------------------
ENUMS = {
    "TransportState": ["stopped", "playing", "paused"],
    "RenderFormat": ["pcm16", "float32"],
    "RenderState": ["idle", "rendering", "streaming", "done", "failed", "cancelled"],
}

# (kind, name, default). Kinds: string number bool trigger list blob color enum:<Enum> vm:<ViewModel>
VIEW_MODELS = [
    ("App", [
        ("bool", "hosted", "false"), ("string", "version", "0.2.0"), ("string", "platformMod", "cmd"),
        # Layout: 0 shows, 1 hides (bound to displayValue)
        ("number", "wideDisplay", "0"), ("number", "narrowDisplay", "1"),
        ("trigger", "moreToggle", ""), ("number", "moreDisplay", "1"),
        ("trigger", "docsToggle", ""),
        ("trigger", "diagnosticsToggle", ""), ("number", "diagnosticsDisplay", "1"),
        ("string", "diagnosticsLabel", "Diagnostics"),
        ("string", "status", "In memory"), ("string", "sampleRate", "48 kHz"),
        ("string", "menuLoop", "Loop"), ("string", "menuFollow", "Follow"), ("string", "menuCollapse", "Collapse all"),
        # Toggle looks: fill, ink (label), edge (border)
        *[(kind, f"{t}{part}", default) for t in ["loop", "follow", "collapse", "docs", "more", "examples", "diagnostics"]
          for kind, part, default in [("color", "Fill", CONTROL), ("color", "Ink", SECONDARY), ("color", "Edge", DIVIDER)]],
    ]),
    ("SongFile", [("string", "path", ""), ("string", "text", ""), ("number", "revision", "0"), ("bool", "dirty", "false")]),
    ("ExampleInfo", [("string", "id", ""), ("string", "title", ""), ("string", "description", ""), ("number", "bpm", "0"),
                     ("string", "genre", ""), ("trigger", "select", ""), ("string", "subtitle", ""),
                     ("number", "hover", "0"), ("number", "current", "0")]),
    ("Diagnostic", [("string", "path", ""), ("number", "line", "0"), ("number", "col", "0"), ("number", "endCol", "0"),
                    ("string", "severity", ""), ("string", "code", ""), ("string", "message", ""),
                    ("trigger", "select", ""), ("string", "where", ""), ("color", "dot", "FFF05A6E"), ("number", "hover", "0")]),
    ("Song", [("list", "files", ""), ("trigger", "load", ""), ("trigger", "new", ""), ("string", "exampleId", "deep-house"),
              ("trigger", "loadExample", ""), ("bool", "autoplay", "false"), ("list", "examples", ""), ("string", "title", ""),
              ("number", "durationSeconds", "0"), ("number", "rows", "0"), ("list", "diagnostics", ""), ("number", "errorCount", "0"),
              ("trigger", "examplesToggle", ""), ("number", "examplesDisplay", "1"), ("string", "examplesLabel", "Examples")]),
    ("Editor", [("trigger", "changed", ""), ("string", "lastChangedPath", ""), ("trigger", "saveRequested", ""),
                ("string", "clipboard", ""), ("trigger", "copied", ""), ("trigger", "pasteRequested", ""),
                ("string", "cursorPath", ""), ("number", "cursorRow", "0"), ("number", "cursorCol", "0"),
                ("bool", "follow", "true"), ("string", "hint", ""), ("trigger", "followToggle", ""),
                ("color", "followColor", CONTROL), ("trigger", "collapseAll", ""), ("string", "collapseLabel", "Collapse all")]),
    ("Transport", [("trigger", "play", ""), ("trigger", "pause", ""), ("trigger", "stop", ""), ("trigger", "playFromCursor", ""),
                   ("enum:TransportState", "state", "stopped"), ("number", "row", "0"), ("number", "bar", "1"), ("number", "beat", "1"),
                   ("number", "seconds", "0"), ("number", "bpm", "120"), ("bool", "loopEnabled", "false"),
                   ("number", "loopStartRow", "0"), ("number", "loopEndRow", "0"), ("number", "masterVolume", "1"),
                   ("number", "load", "0"), ("number", "voices", "0"), ("string", "position", "001.1"),
                   ("string", "playLabel", "Play"), ("trigger", "toggle", ""), ("trigger", "loopToggle", ""),
                   ("string", "info", ""), ("number", "playDisplay", "0"), ("number", "pauseDisplay", "1"),
                   ("string", "loudness", ""), ("number", "lufsShort", "-100"), ("number", "lufsIntegrated", "-100"),
                   ("color", "loopColor", CONTROL), ("string", "time", "00:00.0"), ("string", "tempo", "120"),
                   ("string", "meter", "4/4")]),
    ("Render", [("number", "sampleRate", "48000"), ("enum:RenderFormat", "format", "pcm16"), ("number", "loops", "1"),
                ("number", "fromRow", "0"), ("number", "toRow", "0"), ("number", "maxTail", "8"), ("trigger", "start", ""),
                ("trigger", "cancel", ""), ("enum:RenderState", "state", "idle"), ("number", "progress", "0"),
                ("string", "error", ""), ("number", "totalBytes", "0"), ("blob", "chunk", ""), ("number", "chunkIndex", "0"),
                ("number", "chunkCount", "0"), ("trigger", "chunkReady", ""), ("trigger", "ack", ""), ("string", "label", "Export WAV"),
                ("bool", "realtime", "false")]),
    ("Partition", [("vm:App", "app", ""), ("vm:Song", "song", ""), ("vm:Editor", "editor", ""), ("vm:Transport", "transport", ""),
                   ("vm:Render", "render", "")]),
]

VM_IDS = {}       # name -> (vm id, instance id)
PROP_IDS = {}     # (vm, prop) -> id
ENUM_IDS = {}     # name -> (enum id, {key: value id})


def build_enums():
    out = []
    for name, keys in ENUMS.items():
        eid = nid()
        values = {}
        lines = []
        for k in keys:
            vid = nid()
            values[k] = vid
            lines.append(f'        <DataEnumValue key="{k}" value="{k}" id="{vid}"/>')
        ENUM_IDS[name] = (eid, values)
        out.append(f'    <DataEnumCustom name="{name}" id="{eid}">\n' + "\n".join(lines) + "\n    </DataEnumCustom>")
    return "\n".join(out)


def build_view_models():
    for name, _ in VIEW_MODELS:
        VM_IDS[name] = (nid(), nid())
    out = []
    for name, props in VIEW_MODELS:
        vid, iid = VM_IDS[name]
        decl, vals = [], []
        for kind, pname, default in props:
            pid = nid()
            PROP_IDS[(name, pname)] = pid
            if kind == "string":
                decl.append(f'<ViewModelPropertyString name="{pname}" id="{pid}"/>')
                vals.append(f'<ViewModelInstanceString propertyValue="{default}" viewModelPropertyId="{pid}"/>')
            elif kind == "number":
                decl.append(f'<ViewModelPropertyNumber name="{pname}" id="{pid}"/>')
                vals.append(f'<ViewModelInstanceNumber propertyValue="{default}" viewModelPropertyId="{pid}"/>')
            elif kind == "bool":
                decl.append(f'<ViewModelPropertyBoolean name="{pname}" id="{pid}"/>')
                vals.append(f'<ViewModelInstanceBoolean propertyValue="{default}" viewModelPropertyId="{pid}"/>')
            elif kind == "trigger":
                decl.append(f'<ViewModelPropertyTrigger name="{pname}" id="{pid}"/>')
                vals.append(f'<ViewModelInstanceTrigger viewModelPropertyId="{pid}"/>')
            elif kind == "list":
                decl.append(f'<ViewModelPropertyList name="{pname}" id="{pid}"/>')
                vals.append(f'<ViewModelInstanceList viewModelPropertyId="{pid}"/>')
            elif kind == "blob":
                decl.append(f'<ViewModelPropertyAssetBlob name="{pname}" id="{pid}"/>')
                vals.append(f'<ViewModelInstanceAssetBlob viewModelPropertyId="{pid}"/>')
            elif kind == "color":
                decl.append(f'<ViewModelPropertyColor name="{pname}" id="{pid}"/>')
                vals.append(f'<ViewModelInstanceColor propertyValue="{default}" viewModelPropertyId="{pid}"/>')
            elif kind.startswith("enum:"):
                eid, values = ENUM_IDS[kind[5:]]
                decl.append(f'<ViewModelPropertyEnumCustom enumId="{eid}" name="{pname}" id="{pid}"/>')
                vals.append(f'<ViewModelInstanceEnum propertyValue="{values[default]}" viewModelPropertyId="{pid}"/>')
            elif kind.startswith("vm:"):
                ref_vid, ref_iid = VM_IDS[kind[3:]]
                decl.append(f'<ViewModelPropertyViewModel viewModelReferenceId="{ref_vid}" name="{pname}" id="{pid}"/>')
                vals.append(f'<ViewModelInstanceViewModel propertyValue="{ref_iid}" viewModelPropertyId="{pid}"/>')
        out.append(f'    <ViewModel defaultInstanceId="{iid}" name="{name}" id="{vid}">\n'
                   + "".join(f"        {d}\n" for d in decl)
                   + f'        <ViewModelInstance exports="true" name="Instance" id="{iid}">\n'
                   + "".join(f"            {v}\n" for v in vals)
                   + "        </ViewModelInstance>\n    </ViewModel>")
    return "\n\n".join(out)


def path(vm, prop):
    """Bind path from the root view model to `vm`'s `prop`."""
    root = VM_IDS["Partition"][0]
    if vm == "Partition":
        return f"{root}-{PROP_IDS[('Partition', prop)]}"
    sub = {"App": "app", "Song": "song", "Editor": "editor", "Transport": "transport", "Render": "render"}[vm]
    return f"{root}-{PROP_IDS[('Partition', sub)]}-{PROP_IDS[(vm, prop)]}"


def item_path(vm, prop):
    """Bind path inside a list row bound to `vm`."""
    return f"{VM_IDS[vm][0]}-{PROP_IDS[(vm, prop)]}"


# --- Building blocks -----------------------------------------------------------
LISTENERS = []


def ind(text, n):
    pad = " " * n
    return "\n".join(pad + line if line else line for line in text.split("\n"))


def style(name, **attrs):
    sid = nid()
    a = " ".join(f'{k}="{v}"' for k, v in attrs.items())
    return sid, f'<LayoutComponentStyle {a} name="{name} Style" id="{sid}"/>'


def bound_style(name, display_path, **attrs):
    sid = nid()
    a = " ".join(f'{k}="{v}"' for k, v in attrs.items())
    return sid, (f'<LayoutComponentStyle {a} name="{name} Style" id="{sid}">\n'
                 f'    <DataBindContext sourcePathIds="{display_path}" propertyKey="596"/>\n'
                 f'</LayoutComponentStyle>')


def solid(color, bind=None):
    if bind:
        return (f'<SolidColor colorValue="{color}" name="Color">\n'
                f'    <DataBindContext sourcePathIds="{bind}" propertyKey="37"/>\n</SolidColor>')
    return f'<SolidColor colorValue="{color}" name="Color"/>'


def text(name, content, size, color, font=FONT_UI, bind=None, color_bind=None, width="hug"):
    tid, sid = nid(), nid()
    run_bind = f'\n        <DataBindContext sourcePathIds="{bind}" propertyKey="268"/>\n    ' if bind else ""
    return f'''<Text sizingValue="autoWidth" name="{name}" id="{tid}">
    <LayoutParticipant layoutWidthScaleType="{width}" layoutHeightScaleType="hug" name="{name} Layout"/>
    <TextStylePaint fontSize="{size}" fontAssetId="{font}" name="{name} Style" id="{sid}">
        <Fill name="Fill">{ind(solid(color, color_bind), 8).strip()}</Fill>
    </TextStylePaint>
    <TextValueRun styleId="{sid}" text="{content}" name="Run">{run_bind}</TextValueRun>
</Text>'''


def on_click(target, triggers=(), strings=()):
    acts = []
    for p, value in strings:
        acts.append(f'''    <ListenerViewModelChange>
        <BindablePropertyString propertyValue="{value}">
            <DataBindContext sourcePathIds="{p}" propertyKey="635" direction="true"/>
        </BindablePropertyString>
    </ListenerViewModelChange>''')
    for p in triggers:
        acts.append(f'''    <ListenerViewModelChange>
        <BindablePropertyTrigger propertyValue="1">
            <DataBindContext sourcePathIds="{p}" propertyKey="686" direction="true"/>
        </BindablePropertyTrigger>
    </ListenerViewModelChange>''')
    LISTENERS.append(f'<StateMachineListenerSingle targetId="{target}" listenerTypeValue="click" name="Click" id="{nid()}">\n'
                     + "\n".join(acts) + "\n</StateMachineListenerSingle>")


def shape(name, paths, color=WHITE, color_bind=None, w=None, h=None):
    size = f'layoutWidthScaleType="fixed" layoutHeightScaleType="fixed" width="{w}" height="{h}"' if w else 'layoutWidthScaleType="hug" layoutHeightScaleType="hug"'
    return f'''<Shape name="{name}" id="{nid()}">
    <LayoutParticipant {size} name="{name} Layout"/>
{ind(paths, 4)}
    <Fill name="Fill">{ind(solid(color, color_bind), 8).strip()}</Fill>
</Shape>'''


def chevron(color=SECONDARY):
    return shape("Chevron", '<Triangle rotation="3.14159265" width="7" height="4" name="Path"/>', color)


def button(name, children, trigger=None, fill=CONTROL, edge=DIVIDER, fill_bind=None, edge_bind=None,
           width=None, display=None, gap=4, extra_triggers=(), strings=()):
    """A 24 px control: 7 px padding, 3 px corners, 1 px border (spec Geometry)."""
    bid = nid()
    attrs = dict(flexDirectionValue="row", layoutHeightScaleType="fixed", layoutAlignmentType="center",
                 gapHorizontal=gap, gapHorizontalUnitsValue="points",
                 paddingLeft=7, paddingLeftUnitsValue="points", paddingRight=7, paddingRightUnitsValue="points",
                 cornerRadiusTL=3)
    attrs["layoutWidthScaleType"] = "fixed" if width else "hug"
    sid, st = bound_style(name, display, **attrs) if display else style(name, **attrs)
    triggers = ([trigger] if trigger else []) + list(extra_triggers)
    if triggers or strings:
        on_click(bid, triggers, strings)
    return f'''<LayoutComponent clip="true" width="{width or 40}" height="24" styleId="{sid}" name="{name}" id="{bid}">
{ind(st, 4)}
    <Fill name="Fill">{ind(solid(fill, fill_bind), 8).strip()}</Fill>
    <Stroke thickness="1" name="Border">{ind(solid(edge, edge_bind), 8).strip()}</Stroke>
{ind(children, 4)}
</LayoutComponent>'''


def toggle(name, label, trigger, key, label_bind=None, display=None, extra=""):
    """A toggle whose fill, label and border follow app/<key>Fill, Ink and Edge."""
    children = text(f"{name} Label", label, 12, SECONDARY, bind=label_bind, color_bind=path("App", f"{key}Ink"))
    if extra:
        children += "\n" + extra
    return button(name, children, trigger, fill_bind=path("App", f"{key}Fill"), edge_bind=path("App", f"{key}Edge"),
                  display=display)


def spacer(w, display=None):
    lid = nid()
    attrs = dict(layoutWidthScaleType="fixed", layoutHeightScaleType="fixed")
    sid, st = bound_style("Gap", display, **attrs) if display else style("Gap", **attrs)
    return f'<LayoutComponent width="{w}" height="1" styleId="{sid}" name="Gap" id="{lid}">\n{ind(st, 4)}\n</LayoutComponent>'


def divider(display=None):
    lid = nid()
    attrs = dict(layoutWidthScaleType="fixed", layoutHeightScaleType="fixed",
                 marginLeft=6, marginLeftUnitsValue="points", marginRight=6, marginRightUnitsValue="points")
    sid, st = bound_style("Divider", display, **attrs) if display else style("Divider", **attrs)
    return f'''<LayoutComponent width="1" height="20" styleId="{sid}" name="Divider" id="{lid}">
{ind(st, 4)}
    <Fill name="Fill">{solid(DIVIDER)}</Fill>
</LayoutComponent>'''


def spring():
    lid = nid()
    sid, st = style("Spring", layoutWidthScaleType="fill", layoutHeightScaleType="fixed")
    return f'<LayoutComponent width="0" height="1" styleId="{sid}" name="Spring" id="{lid}">\n{ind(st, 4)}\n</LayoutComponent>'


def group(name, children, display=None, gap=4):
    lid = nid()
    attrs = dict(flexDirectionValue="row", layoutWidthScaleType="hug", layoutHeightScaleType="hug",
                 layoutAlignmentType="centerLeft", gapHorizontal=gap, gapHorizontalUnitsValue="points")
    sid, st = bound_style(name, display, **attrs) if display else style(name, **attrs)
    return f'''<LayoutComponent clip="false" width="10" height="24" styleId="{sid}" name="{name}" id="{lid}">
{ind(st, 4)}
{ind(chr(10).join(children), 4)}
</LayoutComponent>'''


def bar(name, height, children, border="bottom", padding=10, gap=4):
    lid = nid()
    sid, st = style(name, flexDirectionValue="row", layoutWidthScaleType="fill", layoutHeightScaleType="fixed",
                    layoutAlignmentType="centerLeft", gapHorizontal=gap, gapHorizontalUnitsValue="points",
                    paddingLeft=padding, paddingLeftUnitsValue="points", paddingRight=padding, paddingRightUnitsValue="points")
    return f'''<LayoutComponent clip="true" width="1280" height="{height}" styleId="{sid}" name="{name}" id="{lid}">
{ind(st, 4)}
    <Fill name="Fill">{solid(BAR)}</Fill>
{ind(chr(10).join(children), 4)}
</LayoutComponent>'''


def rule(name):
    """A 1 px divider row between bars; as a row of the root column it spans
    the window's width at any size."""
    lid, sid = nid(), nid()
    return f'''<LayoutComponent width="1280" height="1" styleId="{sid}" name="{name}" id="{lid}">
    <LayoutComponentStyle layoutWidthScaleType="fill" layoutHeightScaleType="fixed" name="{name} Style" id="{sid}"/>
    <Fill name="Fill">{solid(DIVIDER)}</Fill>
</LayoutComponent>'''


# --- The chrome ------------------------------------------------------------------
def title_bar():
    status = text("Status", "In memory", 12, SUBDUED, bind=path("App", "status"))
    docs = toggle("Docs", "Docs", path("App", "docsToggle"), "docs")
    title = group("Song Group", [
        text("Song Title", "", 13, WHITE, bind=path("Song", "title")),
        text("Dot", "•", 12, SUBDUED),
        status,
    ], display=path("App", "wideDisplay"), gap=6)
    return bar("Title Bar", 28, [
        spacer(66),  # room for the window controls on macOS
        text("App Name", "Partition", 13, WHITE, font=FONT_UI_BOLD),
        spring(),
        title,
        spring(),
        docs,
    ], padding=8, gap=2)


def transport_bar():
    wide = path("App", "wideDisplay")
    narrow = path("App", "narrowDisplay")
    play = button("Play", shape("Play Icon", '<Triangle rotation="1.5707963" width="11" height="10" name="Path"/>', "FF000000"),
                  path("Transport", "toggle"), fill=WHITE, edge=WHITE, width=36, display=path("Transport", "playDisplay"))
    pause = button("Pause", shape("Pause Icon", '<Rectangle x="-2.5" width="3" height="10" name="Left"/>\n'
                                  '<Rectangle x="2.5" width="3" height="10" name="Right"/>', "FF000000"),
                   path("Transport", "toggle"), fill=WHITE, edge=WHITE, width=36, display=path("Transport", "pauseDisplay"))
    stop = button("Stop", shape("Stop Icon", '<Rectangle width="9" height="9" name="Path"/>', WHITE),
                  path("Transport", "stop"), width=30)
    toggles = group("Toggles", [
        toggle("Loop", "Loop", path("Transport", "loopToggle"), "loop"),
        toggle("Follow", "Follow", path("Editor", "followToggle"), "follow"),
        toggle("Collapse", "Collapse all", path("Editor", "collapseAll"), "collapse", label_bind=path("Editor", "collapseLabel")),
    ], display=wide)
    readout = [
        divider(),
        text("Position", "001.1", 16, WHITE, font=FONT_MONO, bind=path("Transport", "position")),
        divider(),
        text("Time", "00:00.0", 13, SECONDARY, font=FONT_MONO, bind=path("Transport", "time")),
        group("Tempo Group", [
            divider(),
            text("Tempo", "120", 13, WHITE, font=FONT_MONO, bind=path("Transport", "tempo")),
            text("BPM", "BPM", 11, SUBDUED),
            divider(),
            text("Meter", "4/4", 13, SECONDARY, font=FONT_MONO, bind=path("Transport", "meter")),
        ], display=wide, gap=4),
    ]
    examples = toggle("Examples", "Examples", path("Song", "examplesToggle"), "examples",
                      label_bind=path("Song", "examplesLabel"), extra=chevron())
    right = group("Actions", [
        button("New", text("New Label", "New", 12, WHITE), path("Song", "new")),
        examples,
        spacer(8),
        button("Export", text("Export Label", "Export WAV", 12, WHITE, bind=path("Render", "label")),
               path("Render", "start"), fill="FF222222", edge=DIVIDER),
    ], display=wide)
    more = toggle("More", "More", path("App", "moreToggle"), "more", display=narrow,
                  extra=shape("Dots", '<Ellipse x="-5" width="3" height="3" name="A"/>\n<Ellipse width="3" height="3" name="B"/>\n'
                                       '<Ellipse x="5" width="3" height="3" name="C"/>', SECONDARY))
    return bar("Transport", 38, [play, pause, stop, spacer(12, display=wide), toggles, spacer(8), *readout, spring(), right, more],
               padding=10, gap=4)


def footer():
    return bar("Footer", 24, [
        text("Breadcrumb", "", 12, SECONDARY, bind=path("Editor", "hint"), width="fill"),
        text("Loudness", "", 12, SUBDUED, bind=path("Transport", "loudness")),
        divider(display=path("App", "wideDisplay")),
        text("Voices", "0 voices", 12, SUBDUED, bind=path("Transport", "info")),
        divider(display=path("App", "wideDisplay")),
        group("Rate Group", [text("Rate", "48 kHz", 12, SUBDUED, bind=path("App", "sampleRate"))], display=path("App", "wideDisplay")),
        divider(),
        toggle("Diagnostics", "Diagnostics", path("App", "diagnosticsToggle"), "diagnostics",
               label_bind=path("App", "diagnosticsLabel"), extra=chevron()),
    ], border="top", padding=10, gap=4)


def popover(name, children, display_bind, width, top=None, bottom=None, right=8, direction="column", wrap=False):
    pid = nid()
    attrs = dict(positionTypeValue="absolute", positionRight=right, positionRightUnitsValue="points",
                 flexDirectionValue=direction, layoutWidthScaleType="fixed", layoutHeightScaleType="hug",
                 gapHorizontal=4, gapHorizontalUnitsValue="points", gapVertical=2, gapVerticalUnitsValue="points",
                 paddingLeft=4, paddingLeftUnitsValue="points", paddingRight=4, paddingRightUnitsValue="points",
                 paddingTop=4, paddingTopUnitsValue="points", paddingBottom=4, paddingBottomUnitsValue="points",
                 cornerRadiusTL=3, displayValue="none")
    if wrap:
        attrs["flexWrapValue"] = "wrap"
    if top is not None:
        attrs.update(positionTop=top, positionTopUnitsValue="points")
    if bottom is not None:
        attrs.update(positionBottom=bottom, positionBottomUnitsValue="points")
    sid, st = bound_style(name, display_bind, **attrs)
    return f'''<LayoutComponent clip="true" width="{width}" height="40" styleId="{sid}" name="{name}" id="{pid}">
{ind(st, 4)}
    <Fill name="Fill">{solid(BAR)}</Fill>
    <Stroke thickness="1" name="Border">{solid(EDGE)}</Stroke>
{ind(chr(10).join(children), 4)}
</LayoutComponent>'''


def menu_item(name, label, trigger, label_bind=None, close=True):
    triggers = [trigger] + ([path("App", "moreToggle")] if close else [])
    bid = nid()
    sid, st = style(name, flexDirectionValue="row", layoutWidthScaleType="fill", layoutHeightScaleType="fixed",
                    layoutAlignmentType="centerLeft", paddingLeft=8, paddingLeftUnitsValue="points", cornerRadiusTL=2)
    on_click(bid, triggers)
    return f'''<LayoutComponent clip="true" width="180" height="26" styleId="{sid}" name="{name}" id="{bid}">
{ind(st, 4)}
    <Fill name="Fill">{solid(BAR)}</Fill>
{ind(text(f"{name} Label", label, 12, WHITE, bind=label_bind), 4)}
</LayoutComponent>'''


def more_menu():
    items = [
        menu_item("Menu Loop", "Loop", path("Transport", "loopToggle"), path("App", "menuLoop")),
        menu_item("Menu Follow", "Follow", path("Editor", "followToggle"), path("App", "menuFollow")),
        menu_item("Menu Collapse", "Collapse all", path("Editor", "collapseAll"), path("App", "menuCollapse")),
        menu_item("Menu New", "New song", path("Song", "new")),
        menu_item("Menu Examples", "Examples…", path("Song", "examplesToggle")),
        menu_item("Menu Export", "Export WAV", path("Render", "start"), path("Render", "label")),
    ]
    return popover("More Menu", items, path("App", "moreDisplay"), 196, top=68)


def list_popover(name, list_prop, display, width, top=None, bottom=None, wrap=False):
    lid = nid()
    lst = f'''<ArtboardComponentList name="{name} List" id="{lid}">
    <DataBindContext sourcePathIds="{list_prop}" propertyKey="800"/>
</ArtboardComponentList>'''
    return popover(name, [lst], display, width, top=top, bottom=bottom, direction="row" if wrap else "column", wrap=wrap)


def row_artboard(name, vm, x, width, height, children, hover_prop, select_prop):
    ab, ab_sid, sm, layer, bg, bg_sid, hl, hl_sid = (nid() for _ in range(8))
    # Declared after the row, so it paints beneath the row's text (the first
    # sibling draws on top in RML).
    hover = f'''<LayoutComponent clip="true" width="{width}" height="{height}" styleId="{hl_sid}" name="Hover" id="{hl}">
    <DataBindContext sourcePathIds="{item_path(vm, hover_prop)}" propertyKey="18"/>
    <LayoutComponentStyle positionTypeValue="absolute" positionLeft="0" positionLeftUnitsValue="points" positionTop="0" positionTopUnitsValue="points" layoutWidthScaleType="fill" layoutHeightScaleType="fill" cornerRadiusTL="2" name="Hover Style" id="{hl_sid}"/>
    <Fill name="Fill">{solid(SELECTED)}</Fill>
</LayoutComponent>'''
    body = f'''<LayoutComponent clip="true" width="{width}" height="{height}" styleId="{bg_sid}" name="Row" id="{bg}">
    <LayoutComponentStyle flexDirectionValue="row" layoutWidthScaleType="fill" layoutHeightScaleType="fill" layoutAlignmentType="centerLeft" gapHorizontal="8" gapHorizontalUnitsValue="points" paddingLeft="8" paddingLeftUnitsValue="points" paddingRight="8" paddingRightUnitsValue="points" name="Row Style" id="{bg_sid}"/>
{ind(chr(10).join(children), 4)}
</LayoutComponent>'''

    def change(kind, value, prop, key):
        return f'''<ListenerViewModelChange>
    <BindableProperty{kind} propertyValue="{value}">
        <DataBindContext sourcePathIds="{item_path(vm, prop)}" propertyKey="{key}" direction="true"/>
    </BindableProperty{kind}>
</ListenerViewModelChange>'''
    listeners = f'''<StateMachineListenerSingle targetId="{bg}" listenerTypeValue="click" name="Select" id="{nid()}">
{ind(change("Trigger", 1, select_prop, 686), 4)}
</StateMachineListenerSingle>
<StateMachineListenerSingle targetId="{bg}" listenerTypeValue="enter" name="Hover In" id="{nid()}">
{ind(change("Number", 1, hover_prop, 636), 4)}
</StateMachineListenerSingle>
<StateMachineListenerSingle targetId="{bg}" listenerTypeValue="exit" name="Hover Out" id="{nid()}">
{ind(change("Number", 0, hover_prop, 636), 4)}
</StateMachineListenerSingle>'''
    return f'''    <Artboard isComponent="true" defaultStateMachineId="{sm}" viewModelId="{VM_IDS[vm][0]}" clip="true" x="{x}" y="0" width="{width}" height="{height}" styleId="{ab_sid}" name="{name}" id="{ab}">
        <LayoutComponentStyle layoutAlignmentType="centerLeft" name="{name} Artboard Style" id="{ab_sid}"/>
{ind(body, 8)}
{ind(hover, 8)}
        <StateMachine name="{name}" id="{sm}">
            <StateMachineLayer name="Layer" id="{layer}">
                <AnyState x="200" y="-120"/>
                <ExitState x="400" y="-120"/>
                <EntryState/>
            </StateMachineLayer>
{ind(listeners, 12)}
        </StateMachine>
    </Artboard>

    <ComponentAsset artboardId="{ab}" name="{name}"/>'''


def example_row():
    current = nid(), nid()
    marker = f'''<LayoutComponent width="2" height="14" styleId="{current[1]}" name="Current" id="{current[0]}">
    <DataBindContext sourcePathIds="{item_path("ExampleInfo", "current")}" propertyKey="18"/>
    <LayoutComponentStyle layoutWidthScaleType="fixed" layoutHeightScaleType="fixed" name="Current Style" id="{current[1]}"/>
    <Fill name="Fill">{solid(WHITE)}</Fill>
</LayoutComponent>'''
    return row_artboard("ExampleRow", "ExampleInfo", 1400, 300, 26, [
        marker,
        text("Title", "Title", 12, WHITE, bind=item_path("ExampleInfo", "title"), width="fill"),
        text("Subtitle", "genre", 11, SUBDUED, bind=item_path("ExampleInfo", "subtitle")),
    ], "hover", "select")


def diagnostic_row():
    dot = shape("Severity", '<Ellipse width="6" height="6" name="Path"/>', "FFF05A6E", color_bind=item_path("Diagnostic", "dot"), w=6, h=6)
    return row_artboard("DiagnosticRow", "Diagnostic", 1800, 560, 24, [
        dot,
        text("Where", "file:1:1", 11, SUBDUED, font=FONT_MONO, bind=item_path("Diagnostic", "where")),
        text("Message", "message", 12, WHITE, bind=item_path("Diagnostic", "message"), width="fill"),
    ], "hover", "select")


def scene():
    enums = build_enums()
    vms = build_view_models()
    overlays = [
        list_popover("Examples Panel", path("Song", "examples"), path("Song", "examplesDisplay"), 616, top=68, wrap=True),
        more_menu(),
        list_popover("Diagnostics Panel", path("Song", "diagnostics"), path("App", "diagnosticsDisplay"), 576, bottom=28),
    ]
    editor = f'''<LayoutComponent clip="true" width="1280" height="700" styleId="0:15" name="Editor" id="0:14">
    <LayoutComponentStyle layoutWidthScaleType="fill" layoutHeightScaleType="fill" name="Editor Style" id="0:15"/>
    <ScriptedLayout scriptAssetId="0:80" name="App" id="0:12">
        <FocusData name="Focus" id="0:13"/>
    </ScriptedLayout>
</LayoutComponent>'''
    chrome = [*overlays, title_bar(), rule("Title Rule"), transport_bar(), rule("Transport Rule"), editor, rule("Footer Rule"), footer()]
    rows = [example_row(), diagnostic_row()]
    root_vm = VM_IDS["Partition"][0]
    return f'''<Rive version="1" kind="fragment">
    <Artboard defaultStateMachineId="0:7" viewModelId="{root_vm}" clip="true" width="1280" height="800" styleId="0:5" name="Partition" id="0:2">
        <Fill name="Background">
            {solid(CANVAS)}
        </Fill>
        <LayoutComponentStyle name="Artboard Style" id="0:5"/>
        <LayoutComponent clip="true" width="1280" height="800" styleId="0:11" name="Root" id="0:10">
            <LayoutComponentStyle flexDirectionValue="column" layoutWidthScaleType="fill" layoutHeightScaleType="fill" widthUnitsValue="auto" heightUnitsValue="auto" name="Root Style" id="0:11"/>
{ind(chr(10).join(chrome), 12)}
        </LayoutComponent>
        <StateMachine name="Main" id="0:7">
            <StateMachineLayer name="Layer" id="0:8">
                <AnyState x="200" y="-120"/>
                <ExitState x="400" y="-120"/>
                <EntryState/>
            </StateMachineLayer>
{ind(chr(10).join(LISTENERS), 12)}
        </StateMachine>
    </Artboard>

{chr(10).join(rows)}

{enums}

{vms}

    <ScriptAsset file="src/app/app.as" name="app" id="0:80"/>
    <FontAsset file="assets/fonts/Iosevka-Regular.ttf" name="mono" id="{FONT_MONO}"/>
    <FontAsset file="assets/fonts/Iosevka-Bold.ttf" name="mono-bold" id="{FONT_MONO_BOLD}"/>
    <FontAsset file="assets/fonts/BarlowSemiCondensed-Medium.ttf" name="ui" id="{FONT_UI}"/>
    <FontAsset file="assets/fonts/BarlowSemiCondensed-SemiBold.ttf" name="ui-bold" id="{FONT_UI_BOLD}"/>
{examples_assets()}
</Rive>
'''


def examples_assets():
    root = os.path.join(os.path.dirname(OUT), "assets", "examples")
    ids = sorted(f[len("example-"):-len(".song")] for f in os.listdir(root) if f.startswith("example-") and f.endswith(".song"))
    blobs = [f'    <BlobAsset file="assets/examples/example-{i}.song" name="example-{i}" id="0:{100 + n}"/>' for n, i in enumerate(ids)]
    # The song the Rust shell opens (docs/spec.md §12.2); a placeholder otherwise.
    blobs.append('    <BlobAsset file="assets/host/song.song" name="host-song" id="0:99"/>')
    return "\n".join(blobs)


if __name__ == "__main__":
    out = scene()
    with open(OUT, "w") as f:
        f.write(out)
    print(f"wrote {os.path.relpath(OUT)} ({len(out.splitlines())} lines)")
