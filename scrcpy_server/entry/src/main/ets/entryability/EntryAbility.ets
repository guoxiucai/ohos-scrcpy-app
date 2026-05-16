import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import emitter from '@ohos.events.emitter';
import { probeScreenCapture, CaptureConfig } from 'libscrcpy_capture.so';

const DOMAIN = 0xA000;
const TAG = 'EntryAbility';
const CAPTURE_AUTH_EVENT_ID: number = 100001;

export default class EntryAbility extends UIAbility {
  private authWant: Want | null = null;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      this.context.getApplicationContext()
        .setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'setColorMode failed: %{public}s', JSON.stringify(err));
    }
    hilog.info(DOMAIN, TAG, '%{public}s', 'onCreate');
    this.authWant = want;
    this.kickService();
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.authWant = want;
  }

  private kickService(): void {
    const serviceWant: Want = {
      bundleName: 'com.ohos.scrcpy.server',
      abilityName: 'ScrcpyService'
    };
    try {
      this.context.startServiceExtensionAbility(serviceWant);
      hilog.info(DOMAIN, TAG, 'ScrcpyService kicked');
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'kick service failed: %{public}s', JSON.stringify(err));
    }
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    const action: string = (this.authWant?.parameters?.['action'] ?? '') as string;
    if (action === 'screenCaptureAuth') {
      this.handleCaptureAuth(windowStage);
      return;
    }
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'loadContent failed: %{public}s', JSON.stringify(err));
      }
    });
  }

  private handleCaptureAuth(windowStage: window.WindowStage): void {
    const w: number = (this.authWant?.parameters?.['captureWidth'] ?? 720) as number;
    const h: number = (this.authWant?.parameters?.['captureHeight'] ?? 1280) as number;
    hilog.info(DOMAIN, TAG, 'screenCaptureAuth: probing %{public}dx%{public}d', w, h);
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.warn(DOMAIN, TAG, 'loadContent for auth: %{public}s', JSON.stringify(err));
      }
      const cfg: CaptureConfig = {
        width: w, height: h, frameRate: 10, bitrate: 4000000, jpegQuality: 60
      };
      const ok: boolean = probeScreenCapture(cfg);
      hilog.info(DOMAIN, TAG, 'screenCaptureAuth result=%{public}d', ok ? 1 : 0);
      const eventData: emitter.InnerEvent = { eventId: CAPTURE_AUTH_EVENT_ID };
      emitter.emit(eventData);
      this.context.terminateSelf();
    });
  }

  onWindowStageDestroy(): void {}
  onForeground(): void {}
  onBackground(): void {}
}
