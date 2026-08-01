import { AppSession } from '../app/AppSession';
import { KdeRunCommandEntry, RunCommandOutputEvent } from '../service/KdeTypes';
import { goBack, routeParams } from '../common/NavUtil';
import { UiTheme } from '../common/ui/UiTheme';
import { KdeTopBar } from '../common/ui/KdeWidgets';

interface RunCommandRouteParams {
  deviceId: string;
}

/** One rendered terminal line (stdout / stderr / finished prompt). */
interface RunCommandUiLine {
  text: string;
  isError: boolean;
  isPrompt: boolean;
}

/**
 * Run preset commands on the desktop — port of Android RunCommandActivity.
 * We list the desktop's command presets (kdeconnect.runcommand commandList),
 * run one by key (kdeconnect.runcommand.request {key}) and stream its output
 * back (kdeconnect.runcommand.output). Refresh re-requests the list; "添加命令"
 * opens the peer's runcommand config UI (setup); "停止" terminates the command.
 */
@Entry
@Component
struct RunCommandPage {
  @State entries: KdeRunCommandEntry[] = [];
  @State lines: RunCommandUiLine[] = [];
  @State running: boolean = false;
  @State runningKey: string = '';
  @State loaded: boolean = false;
  @State canAdd: boolean = false;
  private deviceId: string = '';
  private outputScroller: Scroller = new Scroller();

  aboutToAppear(): void {
    const params = routeParams(this.getUIContext()) as RunCommandRouteParams;
    if (params && params.deviceId) {
      this.deviceId = params.deviceId;
    }
    const hub = AppSession.getInstance().getService().getClient();
    if (this.deviceId.length > 0) {
      hub.setRunCommandListListenerForDevice(this.deviceId, (list: KdeRunCommandEntry[]) => {
        this.onListUpdate(list);
      });
      hub.setRunCommandOutputListenerForDevice(this.deviceId, (ev: RunCommandOutputEvent) => {
        this.onOutputEvent(ev);
      });
      const initial: KdeRunCommandEntry[] = hub.getRunCommandEntriesForDevice(this.deviceId);
      console.info(`[RunCommand] page open device=${this.deviceId} entries=${initial.length}`);
      this.onListUpdate(initial);
      this.canAdd = hub.getRunCommandCanAddForDevice(this.deviceId);
      console.info(`[RunCommand] canAdd=${this.canAdd}`);
      hub.requestRunCommandListForDevice(this.deviceId);
    }
  }

  private onListUpdate(list: KdeRunCommandEntry[]): void {
    this.entries = list.slice();
    this.loaded = true;
    const hub = AppSession.getInstance().getService().getClient();
    if (this.deviceId.length > 0) {
      this.canAdd = hub.getRunCommandCanAddForDevice(this.deviceId);
    }
    console.info(`[RunCommand] list updated: ${this.entries.length} commands, canAdd=${this.canAdd}`);
  }

  private onOutputEvent(ev: RunCommandOutputEvent): void {
    if (ev.finished) {
      this.running = false;
      this.runningKey = '';
      this.appendLine('>', false, true);
      return;
    }
    this.appendLine(ev.line, ev.isError, false);
  }

  private appendLine(text: string, isError: boolean, isPrompt: boolean): void {
    let base: RunCommandUiLine[] = this.lines;
    if (base.length >= 500) {
      base = base.slice(base.length - 400);
    }
    const line: RunCommandUiLine = { text: text, isError: isError, isPrompt: isPrompt };
    const next: RunCommandUiLine[] = base.slice();
    next.push(line);
    this.lines = next;
    setTimeout(() => {
      this.outputScroller.scrollEdge(Edge.Bottom);
    }, 30);
  }

  private connected(): boolean {
    const hub = AppSession.getInstance().getService().getClient();
    if (this.deviceId.length > 0) {
      const s = hub.getClientForDevice(this.deviceId);
      return s !== null && s.isSessionLive();
    }
    const c = hub.getClient();
    return c !== null && c.isSessionLive();
  }

  private runCommand(entry: KdeRunCommandEntry): void {
    console.info(`[RunCommand] tap run "${entry.name}" key=${entry.key}`);
    if (!this.connected()) {
      this.showToast($r('app.string.run_command_not_connected'));
      return;
    }
    this.lines = [];
    this.running = true;
    this.runningKey = entry.key;
    const hub = AppSession.getInstance().getService().getClient();
    if (this.deviceId.length > 0) {
      hub.runCommandOnDevice(this.deviceId, entry.key);
    } else {
      hub.getClient()?.runCommandOnPeer(entry.key);
    }
  }

  private refresh(): void {
    const hub = AppSession.getInstance().getService().getClient();
    if (this.deviceId.length > 0) {
      hub.requestRunCommandListForDevice(this.deviceId);
    } else {
      hub.getClient()?.requestRunCommandList();
    }
  }

  private addCommand(): void {
    if (!this.connected()) {
      this.showToast($r('app.string.run_command_not_connected'));
      return;
    }
    if (!this.canAdd) {
      this.showToast($r('app.string.run_command_cannot_add'));
      return;
    }
    const hub = AppSession.getInstance().getService().getClient();
    if (this.deviceId.length > 0) {
      hub.setupRunCommandOnDevice(this.deviceId);
    } else {
      hub.getClient()?.setupRunCommandOnPeer();
    }
  }

  private stopCommand(): void {
    const hub = AppSession.getInstance().getService().getClient();
    if (this.deviceId.length > 0) {
      hub.stopRunCommandOnDevice(this.deviceId);
    } else {
      hub.getClient()?.stopRunCommandOnPeer();
    }
  }

  private emptyText(): ResourceStr {
    if (!this.connected()) {
      return $r('app.string.run_command_not_connected');
    }
    if (this.loaded) {
      return $r('app.string.run_command_no_commands');
    }
    return $r('app.string.run_command_loading');
  }

  private showToast(msg: ResourceStr): void {
    this.getUIContext().getPromptAction().showToast({ message: msg, duration: 1500 });
  }

  @Builder
  CommandRow(entry: KdeRunCommandEntry) {
    Column({ space: 2 }) {
      Row() {
        Text(entry.name)
          .fontSize(UiTheme.bodyMd)
          .fontWeight(FontWeight.Medium)
          .fontColor(UiTheme.onSurface)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        if (this.runningKey === entry.key) {
          Text($r('app.string.run_command_running'))
            .fontSize(UiTheme.bodySm)
            .fontColor(UiTheme.primary)
        }
      }
      .width('100%')

      Text(entry.command)
        .fontSize(UiTheme.bodySm)
        .fontColor(UiTheme.textMuted)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
    }
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .width('100%')
    .backgroundColor(UiTheme.cardBg)
    .borderRadius(UiTheme.radiusCard)
    .onClick(() => {
      this.runCommand(entry);
    })
  }

  @Builder
  ActionButton(label: ResourceStr, enabled: boolean, onTap: () => void) {
    Button(label)
      .layoutWeight(1)
      .height(46)
      .fontSize(UiTheme.bodyMd)
      .fontWeight(FontWeight.Medium)
      .fontColor(UiTheme.onSurface)
      .backgroundColor(UiTheme.surfaceVariant)
      .borderRadius(UiTheme.radiusButton)
      .enabled(enabled)
      .opacity(enabled ? 1 : 0.5)
      .onClick(() => {
        onTap();
      })
  }

  build() {
    Column() {
      KdeTopBar({
        title: $r('app.string.plugin_run_command'),
        showBack: true,
        onBack: () => {
          goBack(this.getUIContext());
        }
      })

      if (this.entries.length === 0) {
        Column() {
          Text(this.emptyText())
            .fontSize(UiTheme.bodyMd)
            .fontColor(UiTheme.textMuted)
            .textAlign(TextAlign.Center)
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ top: 48, left: 24, right: 24 })
      } else {
        List({ space: 8 }) {
          ForEach(this.entries, (entry: KdeRunCommandEntry, index: number) => {
            ListItem() {
              this.CommandRow(entry)
            }
          }, (entry: KdeRunCommandEntry, index: number) => `${entry.key}_${index}`)
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: UiTheme.pageHPad, right: UiTheme.pageHPad, top: 4 })
        .scrollBar(BarState.Auto)
      }

      Column({ space: 6 }) {
        Text($r('app.string.run_command_output_title'))
          .fontSize(UiTheme.labelMd)
          .fontColor(UiTheme.textMuted)
          .width('100%')

        List({ space: 2, scroller: this.outputScroller }) {
          ForEach(this.lines, (line: RunCommandUiLine, index: number) => {
            ListItem() {
              Text(line.text)
                .fontSize(UiTheme.bodySm)
                .fontColor(this.lineColor(line))
                .width('100%')
                .maxLines(20)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
          }, (line: RunCommandUiLine, index: number) => `${index}`)
        }
        .height(180)
        .width('100%')
        .backgroundColor(UiTheme.surfaceVariant)
        .borderRadius(UiTheme.radiusCard)
        .scrollBar(BarState.Auto)
      }
      .width('100%')
      .padding({ left: UiTheme.pageHPad, right: UiTheme.pageHPad, bottom: 4 })

      Row({ space: 8 }) {
        this.ActionButton($r('app.string.run_command_refresh'), true, () => {
          this.refresh();
        })
        this.ActionButton($r('app.string.run_command_add'), this.connected(), () => {
          this.addCommand();
        })
        this.ActionButton($r('app.string.run_command_stop'), this.running, () => {
          this.stopCommand();
        })
      }
      .width('100%')
      .padding({ left: UiTheme.pageHPad, right: UiTheme.pageHPad, bottom: 16 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(UiTheme.pageBg)
  }

  private lineColor(line: RunCommandUiLine): ResourceColor {
    if (line.isError) {
      return UiTheme.danger;
    }
    if (line.isPrompt) {
      return UiTheme.primary;
    }
    return UiTheme.onSurface;
  }
}
