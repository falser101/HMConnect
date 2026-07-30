import { display, window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x4B44; // 'KD'
const TAG = 'Immersive';

/** Fully transparent ARGB — system bars draw icons only; app paints the chrome. */
const TRANSPARENT: string = '#00000000';

/**
 * Edge-to-edge layout: app content paints under status / navigation bars so the
 * top toolbar can form one continuous surface with the status bar.
 *
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
          data.type === window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR ||
          data.type === window.AvoidAreaType.TYPE_CUTOUT) {
          ImmersiveUtil.publishInsets(win);
        }
      });
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'avoidAreaChange failed: %{public}s', JSON.stringify(err));
    }
  }

  /**
   * Window fill + transparent system bars.
   * Opaque statusBarColor would paint a separate strip and look "detached" from the app.
   */
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
        statusBarColor: TRANSPARENT,
        navigationBarColor: TRANSPARENT,
        // Keep icons readable on light/dark surfaces
        statusBarContentColor: contentColor,
        navigationBarContentColor: contentColor
      });
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'setWindowSystemBarProperties failed: %{public}s', JSON.stringify(err));
    }
  }

  private static pxToVp(px: number): number {
    // vp = px * 160 / dpi
    let dpi: number = 480;
    try {
      dpi = display.getDefaultDisplaySync().densityDPI;
      if (dpi <= 0) {
        dpi = 480;
      }
    } catch (_e) {
      // fallback
    }
    return px * 160 / dpi;
  }

  private static publishInsets(win: window.Window): void {
    let topPx = 0;
    try {
      const sys = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      topPx = sys.topRect.height;
    } catch (_e) {
      topPx = 0;
    }
    // Notch / cutout may report a taller top than TYPE_SYSTEM on some devices
    try {
      const cut = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_CUTOUT);
      if (cut.topRect.height > topPx) {
        topPx = cut.topRect.height;
      }
    } catch (_e) {
      // optional
    }
    AppStorage.setOrCreate('statusBarHeight', ImmersiveUtil.pxToVp(topPx));

    let bottomPx = 0;
    try {
      const nav = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      bottomPx = nav.bottomRect.height;
      if (bottomPx <= 0) {
        const sys = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
        bottomPx = sys.bottomRect.height;
      }
    } catch (_e) {
      bottomPx = 0;
    }
    AppStorage.setOrCreate('navBarHeight', ImmersiveUtil.pxToVp(bottomPx));
  }
}
