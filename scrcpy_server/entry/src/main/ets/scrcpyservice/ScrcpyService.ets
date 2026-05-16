import { ServiceExtensionAbility, Want } from '@kit.AbilityKit';
import wantAgent from '@ohos.app.ability.wantAgent';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { rpc } from '@kit.IPCKit';
import display from '@ohos.display';
import deviceInfo from '@ohos.deviceInfo';
import emitter from '@ohos.events.emitter';
import { startServer, stopServer, startCapture, stopCapture, setEncoderPaused, broadcastDeviceStatus, CaptureConfig as NativeCaptureConfig } from 'libscrcpy_capture.so';
import { InputInjector } from './InputInjector';
import { ControlSubType } from './Protocol';
import { AppListProvider } from './AppListProvider';

const DOMAIN = 0xA000;
const TAG = 'ScrcpyService';
export const SCRCPY_PORT: number = 53535;

export default class ScrcpyService extends ServiceExtensionAbility {
  private input: InputInjector = new InputInjector();
  private bgRunning: boolean = false;
  private captureActive: boolean = false;
  private captureInitialized: boolean = false;
  private authListening: boolean = false;
  private static readonly CAPTURE_AUTH_EVENT_ID: number = 100001;
  private captureCfg: NativeCaptureConfig = {
    width: 720, height: 1280, frameRate: 10, bitrate: 4_000_000, jpegQuality: 60,
  };

  async onCreate(want: Want): Promise<void> {
    hilog.info(DOMAIN, TAG, '%{public}s', 'onCreate');
    try {
      await this.input.init();
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'input init: %{public}s', JSON.stringify(e));
    }
    this.captureCfg = this.computeCaptureConfig();
    hilog.info(DOMAIN, TAG, 'startServer cfg=%{public}dx%{public}d@%{public}d',
      this.captureCfg.width, this.captureCfg.height, this.captureCfg.frameRate);

    try {
      const ok = startServer(
        SCRCPY_PORT,
        this.captureCfg,
        (hasClient: boolean) => this.onPresence(hasClient),
        (sub: number, body: ArrayBuffer) => this.onControl(sub, body),
      );
      hilog.info(DOMAIN, TAG, 'startServer ok=%{public}d', ok ? 1 : 0);
    } catch (e) {
      const err = e as Error;
      hilog.error(DOMAIN, TAG, 'startServer threw: name=%{public}s msg=%{public}s json=%{public}s',
        err.name ?? '?', err.message ?? '?', JSON.stringify(e));
    }
  }

  onRequest(want: Want, startId: number): void {
    hilog.info(DOMAIN, TAG, 'onRequest startId=%{public}d', startId);
  }

  onConnect(want: Want): rpc.RemoteObject {
    hilog.info(DOMAIN, TAG, '%{public}s', 'onConnect');
    return new rpc.RemoteObject('ScrcpyService');
  }

  async onDestroy(): Promise<void> {
    hilog.info(DOMAIN, TAG, '%{public}s', 'onDestroy');
    if (this.captureActive) {
      try { stopCapture(); } catch (_) {}
      this.captureActive = false;
    }
    if (this.bgRunning) {
      try {
        await backgroundTaskManager.stopBackgroundRunning(this.context);
      } catch (_) {}
      this.bgRunning = false;
    }
    try { stopServer(); } catch (_) {}
  }

  private onPresence(hasClient: boolean): void {
    hilog.info(DOMAIN, TAG, 'presence hasClient=%{public}d captureActive=%{public}d',
      hasClient ? 1 : 0, this.captureActive ? 1 : 0);
    if (hasClient) {
      setEncoderPaused(false);  // 确保新连接时编码器处于运行状态
      this.startCapture();
    } else {
      this.stopCapture();
    }
  }

  private onControl(sub: number, body: ArrayBuffer): void {
    if (sub === ControlSubType.LIST_APPS) {
      this.handleListApps();
      return;
    }
    if (sub === ControlSubType.PAUSE_ENCODER) {
      setEncoderPaused(true);
      return;
    }
    if (sub === ControlSubType.RESUME_ENCODER) {
      setEncoderPaused(false);
      return;
    }
    if (sub === ControlSubType.CHANGE_VIDEO_PARAMS) {
      if (body.byteLength >= 12) {
        const view = new DataView(body);
        const maxShort = view.getInt32(0, false);
        const bitrate = view.getInt32(4, false);
        const frameRate = view.getInt32(8, false);
        this.restartCapture(maxShort, bitrate, frameRate);
      }
      return;
    }
    this.input.handle(sub, new Uint8Array(body));
  }

  private async handleListApps(): Promise<void> {
    try {
      const payload = await AppListProvider.buildAppListPayload();
      broadcastDeviceStatus(payload);
      hilog.info(DOMAIN, TAG, 'broadcast appList bytes=%{public}d', payload.byteLength);
    } catch (e) {
      const err = e as Error;
      hilog.error(DOMAIN, TAG, 'handleListApps fail: %{public}s', err.message ?? '?');
    }
  }

  private startCapture(): void {
    if (this.captureActive) {
      hilog.warn(DOMAIN, TAG, 'startCapture already active');
      return;
    }
    this.input.setStreamSize(this.captureCfg.width, this.captureCfg.height);
    const ok: boolean = startCapture(this.captureCfg);
    hilog.info(DOMAIN, TAG, 'startCapture result=%{public}d', ok ? 1 : 0);
    if (ok) {
      this.captureActive = true;
      this.startBackgroundTask().catch((e: Error) =>
        hilog.warn(DOMAIN, TAG, 'bg task: %{public}s', e.message));
      return;
    }
    if (deviceInfo.sdkApiVersion < 15) {
      hilog.info(DOMAIN, TAG, 'API %{public}d < 15, launching EntryAbility for capture auth',
        deviceInfo.sdkApiVersion);
      this.launchCaptureAuth();
    } else {
      hilog.error(DOMAIN, TAG, 'startCapture failed');
    }
  }

  private launchCaptureAuth(): void {
    if (!this.authListening) {
      this.authListening = true;
      const eventData: emitter.InnerEvent = { eventId: ScrcpyService.CAPTURE_AUTH_EVENT_ID };
      emitter.on(eventData, () => {
        hilog.info(DOMAIN, TAG, 'capture auth completed, retrying startCapture');
        emitter.off(ScrcpyService.CAPTURE_AUTH_EVENT_ID);
        this.authListening = false;
        this.startCapture();
      });
    }
    const want: Want = {
      bundleName: 'com.ohos.scrcpy.server',
      abilityName: 'EntryAbility',
      parameters: {
        action: 'screenCaptureAuth',
        captureWidth: this.captureCfg.width,
        captureHeight: this.captureCfg.height,
      }
    };
    try {
      this.context.startAbility(want);
    } catch (e) {
      const err = e as Error;
      hilog.error(DOMAIN, TAG, 'startAbility for auth failed: %{public}s', err.message ?? '?');
    }
  }

  private stopCapture(): void {
    if (!this.captureActive) return;
    this.captureActive = false;
    try { stopCapture(); } catch (_) {}
    hilog.info(DOMAIN, TAG, 'stopCapture done');
    if (this.bgRunning) {
      backgroundTaskManager.stopBackgroundRunning(this.context).then(() => {
        this.bgRunning = false;
      }).catch((e: Error) =>
        hilog.warn(DOMAIN, TAG, 'stop bg: %{public}s', e.message));
    }
  }

  private restartCapture(maxShort: number, bitrate: number, frameRate: number): void {
    hilog.info(DOMAIN, TAG, 'restartCapture maxShort=%{public}d bitrate=%{public}d fps=%{public}d',
      maxShort, bitrate, frameRate);
    this.stopCapture();
    let dispW = 720;
    let dispH = 1280;
    try {
      const def = display.getDefaultDisplaySync();
      dispW = def.width;
      dispH = def.height;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'getDefaultDisplay in restartCapture: %{public}s', JSON.stringify(e));
    }
    const short = Math.min(dispW, dispH);
    let scale = 1.0;
    if (short > maxShort) {
      scale = maxShort / short;
    }
    let w = Math.floor(dispW * scale);
    let h = Math.floor(dispH * scale);
    w -= w % 2;
    h -= h % 2;
    this.captureCfg = {
      width: w,
      height: h,
      frameRate: frameRate,
      bitrate: bitrate,
      jpegQuality: this.captureCfg.jpegQuality,
    };
    hilog.info(DOMAIN, TAG, 'restartCapture cfg=%{public}dx%{public}d@%{public}d', w, h, frameRate);
    this.startCapture();
  }

  private computeCaptureConfig(): NativeCaptureConfig {
    let dispW = 720;
    let dispH = 1280;
    let dispFps = 30;
    try {
      const def = display.getDefaultDisplaySync();
      dispW = def.width;
      dispH = def.height;
      const refresh = (def.refreshRate !== undefined && def.refreshRate > 0) ? def.refreshRate : 30;
      dispFps = Math.min(60, refresh);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'getDefaultDisplay: %{public}s', JSON.stringify(e));
    }
    const maxShort = 720;
    const short = Math.min(dispW, dispH);
    let scale = 1.0;
    if (short > maxShort) scale = maxShort / short;
    let w = Math.floor(dispW * scale);
    let h = Math.floor(dispH * scale);
    w -= w % 2;
    h -= h % 2;
    return {
      width: w,
      height: h,
      frameRate: Math.min(10, dispFps),
      bitrate: 4_000_000,
      jpegQuality: 60,
    };
  }

  private async startBackgroundTask(): Promise<void> {
    if (this.bgRunning) return;
    const info: wantAgent.WantAgentInfo = {
      wants: [{
        bundleName: 'com.ohos.scrcpy.server',
        abilityName: 'ScrcpyService',
      }],
      actionType: wantAgent.OperationType.START_SERVICE_EXTENSION,
      requestCode: 0,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG],
    };
    const agent = await wantAgent.getWantAgent(info);
    await backgroundTaskManager.startBackgroundRunning(
      this.context,
      backgroundTaskManager.BackgroundMode.DATA_TRANSFER,
      agent);
    this.bgRunning = true;
  }
}
