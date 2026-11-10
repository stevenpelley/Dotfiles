// Context menus (Herdr's items). Opened as a popup with
// props { tab: "pane" | "tab" | "space" | "global", target }.
// ↑/↓ move, Enter runs, Esc closes. An item is [label, command, args];
// a command "worktree" opens the worktree dialog instead.

import { View, div, svg } from "gpui-kit";
import { v_flex, h_flex } from "gpui-base";
import { run, props, closeOverlay, openOverlay, theme, keys, terminals, spaces, panes, exec, notify } from "herdr";

// Where a space is now: its first terminal's live folder, else where it was made.
function place(s) {
  const tabs = new Set((s.tabs ?? []).map((c) => c.id));
  return panes().find((p) => tabs.has(p.tab) && p.cwd)?.cwd || s.folder;
}

// A space's checkout: "main" (a repo's own), "linked" (a worktree), or null.
async function checkout(folder, on) {
  const top = await exec("git", ["rev-parse", "--show-toplevel"], { cwd: folder, on });
  const common = await exec("git", ["rev-parse", "--path-format=absolute", "--git-common-dir"], { cwd: folder, on });
  if (top.code !== 0 || common.code !== 0) return null;
  return common.stdout.trim() === `${top.stdout.trim()}/.git` ? "main" : "linked";
}

// The space holding a pane, and its tabs other than the pane's own.
function otherTabs(paneId) {
  const pane = panes().find((x) => x.pane === paneId);
  const space = pane && spaces().find((s) => (s.tabs ?? []).some((t) => t.id === pane.tab));
  return space ? space.tabs.filter((t) => t.id !== pane.tab) : [];
}

// "Move to tab…": the destinations for one terminal.
function moveItems(tg) {
  return [
    ...otherTabs(tg.pane).map((t) => [`Tab ${t.name}`, "move-to", { terminal: tg.terminal, tab: t.id }]),
    ["New tab", "move-to", { terminal: tg.terminal, tab: null }],
  ];
}

function items(p, git, mode) {
  p = p ?? {};
  const tg = p.target ?? {};
  if (mode === "move") return moveItems(tg);
  switch (p.tab) {
    case "pane": {
      // A kept sub-agent can go back under its parent, still running.
      const all = terminals();
      const term = all.find((t) => t.address === tg.terminal);
      const parent = term?.parent && all.find((t) => t.address === term.parent);
      // Once they go to the program, Shift+right-click still opens this menu.
      const toProgram = term?.labels?.["herdr.right-click"] === "program";
      // A terminal shown outside a tab (a layout terminal block, a window) has
      // no pane to split, zoom or close: its pane is the block's id.
      const inTab = panes().some((pane) => pane.pane === tg.pane);
      return [
        ...(inTab
          ? [
              ["Split right", "pane.split", { direction: "right", pane: tg.pane }],
              ["Split down", "pane.split", { direction: "down", pane: tg.pane }],
              ["Zoom", "pane.zoom", { pane: tg.pane }],
              ...(term ? [["Move to tab…", "move", {}]] : []),
            ]
          : []),
        ...(term
          ? [
              toProgram
                ? ["Use Herdr right-click menu", "terminal.right_click", { terminal: term.address, to: "menu" }]
                : ["Send right-clicks to pane", "terminal.right_click", { terminal: term.address, to: "program" }],
            ]
          : []),
        ...(parent ? [[`Send back to ${parent.name || parent.address}`, "terminal.park", { terminal: term.address }]] : []),
        ...(inTab ? [["Close pane", "pane.close", { pane: tg.pane }]] : []),
      ];
    }
    case "tab":
      return [
        ["Rename", "tab.rename", { id: tg.id }],
        ["New tab", "tab.new", { space: tg.space }],
        ["Close", "tab.close", { id: tg.id }],
      ];
    case "space":
      return [
        ["Rename", "space.rename", { id: tg.id }],
        ...(git ? [["New worktree", "worktree", { space: tg.id, action: "new" }], ["Open worktree", "worktree", { space: tg.id, action: "open" }]] : []),
        ...(git === "linked" ? [["Remove worktree", "worktree", { space: tg.id, action: "remove" }]] : []),
        ["Close", "space.close", { id: tg.id }],
      ];
    default:
      return [
        ["New space", "space.new", {}],
        ["Keybinds", "app.help", {}],
        ["Theme: graphite", "app.theme", { name: "graphite" }],
        ["Theme: ink", "app.theme", { name: "ink" }],
        ["Theme: moss", "app.theme", { name: "moss" }],
        ["Theme: atom one dark", "app.theme", { name: "atom-one-dark" }],
      ];
  }
}

function menuIcon(command) {
  if (command === "move" || command === "move-to") return "mods/workspace-chrome/layers.svg";
  const name = command.endsWith(".close") ? "x" : command.endsWith(".rename") ? "square-pen" : command.endsWith(".new") ? "plus" : command === "worktree" ? "git-branch" : command === "app.help" ? "terminal" : command === "app.theme" ? "settings" : command === "pane.split" ? "panel-right" : command === "pane.zoom" ? "square" : "terminal";
  return `mods/workspace-chrome/${name}.svg`;
}

// The key bound to a command, for the hint on the right.
function shortcut(name, args) {
  // `pane.split:right` binds pane.split with { direction: "right" }.
  const value = args && Object.values(args)[0];
  const k = keys().find((b) => b.section === "global" && (b.action === name || b.action === `${name}:${value}`));
  return k ? k.keys : "";
}

export default class Menu extends View {
  init(_props, cx) {
    this.at = 0;
    this.git = null;
    this.handle = cx.focus_handle();
    this.handle.focus();
    const p = props();
    const space = p?.tab === "space" && spaces().find((s) => s.id === p.target?.id);
    const folder = space && place(space);
    if (folder)
      cx.spawn(async (cx) => {
        this.git = await checkout(folder, space.machine).catch(() => null);
        cx.notify();
      });
  }

  choose(i, cx) {
    const it = items(props(), this.git, this.mode)[i];
    if (!it) return;
    // "Move to tab…" swaps this popup's list for the destinations.
    if (it[1] === "move") {
      this.mode = "move";
      this.at = 0;
      cx.notify();
      return;
    }
    if (it[1] === "move-to") {
      this.move(it[2], cx);
      return;
    }
    closeOverlay(props()?.overlay);
    if (it[1] === "worktree") openOverlay({ mod: "worktree", kind: "dialog", ...(it[2].action === "open" ? { width: 560, height: 480 } : { width: 440, height: 260 }), props: it[2] });
    else run(it[1], it[2]);
  }

  // Take the pane away (the program keeps running), then give it one beside
  // the destination tab's focused pane, or a tab of its own. Parking is
  // pending until the core replies, and keep fails ("no running terminal")
  // until the app has caught up, so wait for the app's own view to show it
  // parked, then keep until a pane for it appears. The popup stays open
  // meanwhile: closing it would cancel this task.
  move({ terminal, tab }, cx) {
    if (this.moving) return;
    this.moving = true;
    cx.notify();
    run("terminal.park", { terminal });
    cx.spawn(async (cx) => {
      const term = () => terminals().find((x) => x.address === terminal);
      const hasPane = () => panes().some((p) => p.terminal === terminal);
      const parked = () => term() && !term().labels?.["herdr.tab"] && !hasPane();
      for (let n = 0; n < 50 && !parked(); n++) await cx.sleep(100);
      if (!parked()) {
        notify({ title: "Move to tab", body: `${terminal} didn't leave its tab.`, level: "error" });
      } else {
        for (let n = 0; n < 5 && !hasPane(); n++) {
          if (tab) {
            run("tab.select", { id: tab });
            run("terminal.keep", { terminal, place: "right" });
          } else run("terminal.keep", { terminal, place: "tab" });
          for (let w = 0; w < 10 && !hasPane(); w++) await cx.sleep(100);
        }
        if (!hasPane()) notify({ title: "Move to tab", body: `${terminal} is still running but has no pane; find it in the agents list or with hc ls.`, level: "error" });
      }
      closeOverlay(props()?.overlay);
    });
  }

  render(cx) {
    const t = theme();
    if (this.moving) return v_flex().id("menu").w_full().p(12).bg(t.popover).text_size(12.8).text_color(t.muted).child("Moving…");
    const list = items(props(), this.git, this.mode);
    return v_flex()
      .id("menu")
      .track_focus(this.handle)
      .w_full()
      .min_h(0)
      .p(5)
      .bg(t.popover)
      .text_size(12.8)
      .on_key_down((e, cx) => {
        if (e.key === "down") this.at = (this.at + 1) % list.length;
        else if (e.key === "up") this.at = (this.at + list.length - 1) % list.length;
        else if (e.key === "enter") this.choose(this.at, cx);
        else if (e.key === "escape") closeOverlay(props().overlay);
        else return;
        cx.notify();
      })
      .children(
        list.map((it, i) =>
          v_flex()
            .when(i > 0 && (it[1].endsWith(".close") || it[1] === "app.help" || (it[1] === "app.theme" && list[i - 1][1] !== "app.theme")), el => el.child(div().mx(7).my(4).h(1).bg(t.border)))
            .child(h_flex()
            .id(`mi-${i}`)
            .h(31)
            .px(8)
            .gap(9)
            .rounded(7)
            .items_center()
            .justify_between()
            .text_color(t.foreground)
            .when(i === this.at, (el) => el.bg(t.selected))
            .hover((s) => s.bg(t.hover))
            .on_click((_e, cx) => this.choose(i, cx))
            .child(svg(menuIcon(it[1])).size(14).flex_none().text_color(t.muted))
            .child(div().flex_1().child(it[0]))
            .child(div().text_size(11).text_color(t.dim).child(shortcut(it[1], it[2])))),
        ),
      );
  }
}
