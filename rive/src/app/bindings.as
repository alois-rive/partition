// The view-model contract (docs/spec.md §11): typed access to the Partition
// view model and its nested view models, with trigger fires collected as
// action names the app handles once per frame.

import { Property, PropertyBlob, PropertyList, ViewModel } from "rive/data";

class Queue {
    items: Array<string> = [];
}

function nested(root: ViewModel, name: string): ViewModel? {
    let p = root.getViewModel(name);
    return p != null ? p.value : null;
}

export class Bindings {
    actions: Queue = new Queue();
    // Last values written, so unchanged ones are not written again.
    written: Map<string, string> = new Map<string, string>();

    app: ViewModel;
    song: ViewModel;
    editor: ViewModel;
    transport: ViewModel;
    render: ViewModel;

    constructor(public root: ViewModel, app: ViewModel, song: ViewModel, editor: ViewModel, transport: ViewModel, render: ViewModel) {
        this.app = app;
        this.song = song;
        this.editor = editor;
        this.transport = transport;
        this.render = render;
        this.listen(song, "load", "song.load");
        this.listen(song, "new", "song.new");
        this.listen(song, "loadExample", "song.loadExample");
        this.listen(song, "examplesToggle", "menu.toggle");
        this.listen(editor, "pasteRequested", "editor.paste");
        this.listen(editor, "followToggle", "editor.followToggle");
        this.listen(editor, "collapseAll", "editor.collapseAll");
        this.listen(app, "moreToggle", "app.moreToggle");
        this.listen(app, "docsToggle", "app.docsToggle");
        this.listen(app, "diagnosticsToggle", "app.diagnosticsToggle");
        this.listen(transport, "play", "transport.play");
        this.listen(transport, "pause", "transport.pause");
        this.listen(transport, "stop", "transport.stop");
        this.listen(transport, "playFromCursor", "transport.playFromCursor");
        this.listen(transport, "toggle", "transport.toggle");
        this.listen(transport, "loopToggle", "transport.loopToggle");
        this.listen(render, "start", "render.start");
        this.listen(render, "cancel", "render.cancel");
        this.listen(render, "ack", "render.ack");
        // Values a host (or `rive --data`) may set after start.
        this.watch(song.getString("exampleId"), "song.loadExample");
        this.watch(song.getBoolean("autoplay"), "song.autoplay");
    }

    watch(p: Property?, action: string): void {
        if (p == null) return;
        let q = this.actions;
        p.addListener(() => {
            q.items.push(action);
        });
    }

    static bind(root: ViewModel?): Bindings? {
        if (root == null) return null;
        let app = nested(root, "app");
        let song = nested(root, "song");
        let editor = nested(root, "editor");
        let transport = nested(root, "transport");
        let render = nested(root, "render");
        if (app == null || song == null || editor == null || transport == null || render == null) return null;
        return new Bindings(root, app, song, editor, transport, render);
    }

    // Pushes `action` whenever trigger `name` of `vm` fires (also for list items).
    listen(vm: ViewModel, name: string, action: string): void {
        let t = vm.getTrigger(name);
        if (t == null) return;
        let q = this.actions;
        t.addListener(() => {
            q.items.push(action);
        });
    }

    // The actions fired since the last call, each once.
    takeActions(): Array<string> {
        let out = new Array<string>();
        let items = this.actions.items;
        for (let i = 0; i < items.length; i++) if (!out.includes(items[i])) out.push(items[i]);
        this.actions.items = [];
        return out;
    }

    // --- Typed access -----------------------------------------------------------

    str(vm: ViewModel, name: string, fallback: string = ""): string {
        let p = vm.getString(name);
        return p != null ? p.value : fallback;
    }

    num(vm: ViewModel, name: string, fallback: f64 = 0): f64 {
        let p = vm.getNumber(name);
        return p != null ? p.value : fallback;
    }

    bool(vm: ViewModel, name: string, fallback: bool = false): bool {
        let p = vm.getBoolean(name);
        return p != null ? p.value : fallback;
    }

    enumValue(vm: ViewModel, name: string, fallback: string): string {
        let p = vm.getEnum(name);
        return p != null ? p.value : fallback;
    }

    // Writers skip values that have not changed since the last write.
    setStr(vm: ViewModel, key: string, name: string, value: string): void {
        let k = key + "/" + name;
        if (this.written.has(k) && this.written.get(k) == value) return;
        this.written.set(k, value);
        let p = vm.getString(name);
        if (p != null) p.value = value;
    }

    setNum(vm: ViewModel, key: string, name: string, value: f64): void {
        let k = key + "/" + name;
        let s = value.toString();
        if (this.written.has(k) && this.written.get(k) == s) return;
        this.written.set(k, s);
        let p = vm.getNumber(name);
        if (p != null) p.value = value;
    }

    setBool(vm: ViewModel, key: string, name: string, value: bool): void {
        let k = key + "/" + name;
        let s = value ? "1" : "0";
        if (this.written.has(k) && this.written.get(k) == s) return;
        this.written.set(k, s);
        let p = vm.getBoolean(name);
        if (p != null) p.value = value;
    }

    setEnum(vm: ViewModel, key: string, name: string, value: string): void {
        let k = key + "/" + name;
        if (this.written.has(k) && this.written.get(k) == value) return;
        this.written.set(k, value);
        let p = vm.getEnum(name);
        if (p != null) p.value = value;
    }

    setColor(vm: ViewModel, key: string, name: string, value: u32): void {
        let k = key + "/" + name;
        let s = value.toString();
        if (this.written.has(k) && this.written.get(k) == s) return;
        this.written.set(k, s);
        let p = vm.getColor(name);
        if (p != null) p.value = value;
    }

    fire(vm: ViewModel, name: string): void {
        let t = vm.getTrigger(name);
        if (t != null) t.fire();
    }

    list(vm: ViewModel, name: string): PropertyList? {
        return vm.getList(name);
    }

    blob(vm: ViewModel, name: string): PropertyBlob? {
        return vm.getBlob(name);
    }
}

// Makes a new instance of view model `type` for a list (the file must define it).
export function newItem(type: string): ViewModel {
    return ViewModel.create(type);
}

export function itemStr(vm: ViewModel, name: string): string {
    let p = vm.getString(name);
    return p != null ? p.value : "";
}

export function itemNum(vm: ViewModel, name: string): f64 {
    let p = vm.getNumber(name);
    return p != null ? p.value : 0;
}

export function setItemStr(vm: ViewModel, name: string, value: string): void {
    let p = vm.getString(name);
    if (p != null) p.value = value;
}

export function setItemNum(vm: ViewModel, name: string, value: f64): void {
    let p = vm.getNumber(name);
    if (p != null) p.value = value;
}

export function setItemBool(vm: ViewModel, name: string, value: bool): void {
    let p = vm.getBoolean(name);
    if (p != null) p.value = value;
}

export function itemBool(vm: ViewModel, name: string): bool {
    let p = vm.getBoolean(name);
    return p != null ? p.value : false;
}

export function setItemColor(vm: ViewModel, name: string, value: u32): void {
    let p = vm.getColor(name);
    if (p != null) p.value = value;
}
