import { display, window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x4B44; // 'KD'
const TAG = 'Immersive';

/**
 * Full-screen layout so app content paints under status / navigation bars.
 * Call prepaint() from EntryAbility before loadContent.
 */
export class ImmersiveUtil {
  private static mainWindow: window.Window | null = null;

  static prepaint(stage: window.WindowStage, bgColor: string, contentColor: string): void {
    let win: window.Window;
    try {
      win = stage.getMainWindowSync();
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'getMainWindowSync failed: %{public}s', JSON.stringify(err));
      return;
    }
    ImmersiveUtil.mainWindow = win;

    try {
      // Layout extends under system bars — required for continuous chrome.
      win.setWindowLayoutFullScreen(true);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'setWindowLayoutFullScreen failed: %{public}s', JSON.stringify(err));
    }

    ImmersiveUtil.applyChrome(bgColor, contentColor);
    ImmersiveUtil.publishInsets(win);

    try {
      win.on('avoidAreaChange', (data) => {
        if (data.type === window.AvoidAreaType.TYPE_SYSTEM ||
          data.type === window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR) {
          ImmersiveUtil.publishInsets(win);
        }
      });
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'avoidAreaChange failed: %{public}s', JSON.stringify(err));
    }
  }

  static applyChrome(bgColor: string, contentColor: string): void {
    let win = ImmersiveUtil.mainWindow;
    if (!win) {
      return;
    }
    try {
      win.setWindowBackgroundColor(bgColor);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'setWindowBackgroundColor failed: %{public}s', JSON.stringify(err));
    }
    try {
      win.setWindowSystemBarProperties({
        statusBarColor: bgColor,
        navigationBarColor: bgColor,
        // Keep icons readable on light/dark surfaces
        statusBarContentColor: contentColor,
        navigationBarContentColor: contentColor
      });
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'setWindowSystemBarProperties failed: %{public}s', JSON.stringify(err));
    }
  }

  private static publishInsets(win: window.Window): void {
    // px → vp: vp = px * 160 / dpi
    let dpi: number = 480;
    try {
      dpi = display.getDefaultDisplaySync().densityDPI;
    } catch (_e) {
      // fallback to 480
    }
    try {
      let sys = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      let topPx = sys.topRect.height;
      let topVp = topPx * 160 / dpi;
      AppStorage.setOrCreate('statusBarHeight', topVp);
    } catch (err) {
      AppStorage.setOrCreate('statusBarHeight', 0);
    }
    try {
      let nav = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      let bottomPx = nav.bottomRect.height;
      if (bottomPx <= 0) {
        // Fallback: some devices report cutout via SYSTEM bottom
        let sys = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
        bottomPx = sys.bottomRect.height;
      }
      AppStorage.setOrCreate('navBarHeight', bottomPx * 160 / dpi);
    } catch (err) {
      AppStorage.setOrCreate('navBarHeight', 0);
    }
  }
}
