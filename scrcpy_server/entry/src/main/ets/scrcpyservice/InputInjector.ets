import { inputEventClient } from '@kit.InputKit';
import { Action, SourceType, TouchEvent, Touch, ToolType } from '@ohos.multimodalInput.touchEvent';
import { Action as MouseAction, Button as MouseButton, Axis, AxisValue,
  MouseEvent, ToolType as MouseToolType } from '@ohos.multimodalInput.mouseEvent';
import { KeyCode } from '@ohos.multimodalInput.keyCode';
import { hilog } from '@kit.PerformanceAnalysisKit';
import brightness from '@ohos.brightness';
import { audio } from '@kit.AudioKit';
import { ControlSubType } from './Protocol';
import display from '@ohos.display';
import util from '@ohos.util';
import pasteboard from '@ohos.pasteboard';

const DOMAIN = 0xA000;
const TAG = 'InputInjector';

interface SimpleKeyEvent {
  isPressed: boolean;
  keyCode: number;
  keyDownDuration: number;
  isIntercepted: boolean;
}

export class InputInjector {
  private currentBrightness: number = 128;
  private volumeMgr: audio.AudioVolumeManager | null = null;
  private volumeGroup: audio.AudioVolumeGroupManager | null = null;
  private streamMgr: audio.AudioStreamManager | null = null;
  // Stream dimensions (what the client sees). Injected coordinates are scaled from
  // stream space to real device screen space.
  private streamWidth: number = 0;
  private streamHeight: number = 0;
  private realWidth: number = 0;
  private realHeight: number = 0;
  // Track pressedTime per pointerId so MOVE/UP reuse the original DOWN timestamp.
  private pointerDownTime: Map<number, number> = new Map<number, number>();
  // Monotonically increasing event ID for touch injection.
  private eventId: number = 0;
  // 最后一次触摸的设备坐标（用于 uitest inputText 定位）
  private lastTouchX: number = 0;
  private lastTouchY: number = 0;

  async init(): Promise<void> {
    try {
      const am = audio.getAudioManager();
      this.volumeMgr = am.getVolumeManager();
      this.volumeGroup = await this.volumeMgr.getVolumeGroupManager(audio.DEFAULT_VOLUME_GROUP_ID);
      this.streamMgr = am.getStreamManager();
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'audio init: %{public}s', JSON.stringify(e));
    }
    this.refreshDisplaySize();
  }

  /** Set the stream resolution so touch coordinates can be scaled to real device pixels. */
  setStreamSize(width: number, height: number): void {
    this.streamWidth = width;
    this.streamHeight = height;
  }

  private refreshDisplaySize(): void {
    try {
      const def = display.getDefaultDisplaySync();
      this.realWidth = def.width;
      this.realHeight = def.height;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'getDisplay: %{public}s', JSON.stringify(e));
    }
  }

  handle(sub: number, payload: Uint8Array): void {
    switch (sub) {
      case ControlSubType.TOUCH_DOWN:
      case ControlSubType.TOUCH_MOVE:
      case ControlSubType.TOUCH_UP:
        this.handleTouch(sub, payload);
        break;
      case ControlSubType.POWER_KEY:
        this.injectKey(KeyCode.KEYCODE_POWER);
        break;
      case ControlSubType.HOME_KEY:
        this.injectKey(KeyCode.KEYCODE_HOME);
        break;
      case ControlSubType.BACK_KEY:
        this.injectKey(KeyCode.KEYCODE_BACK);
        break;
      case ControlSubType.VOLUME_UP:
      case ControlSubType.VOLUME_DOWN:
        this.adjustVolume(sub === ControlSubType.VOLUME_UP);
        break;
      case ControlSubType.BRIGHTNESS_UP:
      case ControlSubType.BRIGHTNESS_DOWN:
        this.adjustBrightness(sub === ControlSubType.BRIGHTNESS_UP);
        break;
      case ControlSubType.MOUSE_EVENT:
        this.handleMouseEvent(payload);
        break;
      case ControlSubType.KEY_EVENT:
        this.handleKeyEvent(payload);
        break;
      case ControlSubType.TEXT_INPUT:
        this.handleTextInput(payload);
        break;
      default:
        hilog.info(DOMAIN, TAG, 'unhandled sub=%{public}d', sub);
    }
  }

  private handleTouch(sub: number, payload: Uint8Array): void {
    if (payload.byteLength < 10) return;
    const view = new DataView(payload.buffer, payload.byteOffset, payload.byteLength);
    const rawX = view.getUint32(0, false);
    const rawY = view.getUint32(4, false);
    const pointerId = view.getUint16(8, false);

    // Scale from stream coordinates to real device coordinates.
    let x = rawX;
    let y = rawY;
    if (this.streamWidth > 0 && this.streamHeight > 0 &&
        this.realWidth > 0 && this.realHeight > 0) {
      x = Math.round(rawX * this.realWidth / this.streamWidth);
      y = Math.round(rawY * this.realHeight / this.streamHeight);
    }
    // Clamp to real screen bounds.
    x = Math.max(0, Math.min(this.realWidth > 0 ? this.realWidth - 1 : x, x));
    y = Math.max(0, Math.min(this.realHeight > 0 ? this.realHeight - 1 : y, y));

    let action: Action;
    const now = Date.now();
    let pressedTime = now;
    if (sub === ControlSubType.TOUCH_DOWN) {
      action = Action.DOWN;
      this.pointerDownTime.set(pointerId, now);
      this.lastTouchX = x;
      this.lastTouchY = y;
    } else if (sub === ControlSubType.TOUCH_MOVE) {
      action = Action.MOVE;
      pressedTime = this.pointerDownTime.get(pointerId) ?? now;
    } else {
      action = Action.UP;
      pressedTime = this.pointerDownTime.get(pointerId) ?? now;
      this.pointerDownTime.delete(pointerId);
    }

    const touch: Touch = {
      id: pointerId,
      pressedTime: pressedTime,
      screenX: x,
      screenY: y,
      windowX: x,
      windowY: y,
      pressure: 1.0,
      width: 0,
      height: 0,
      tiltX: 0,
      tiltY: 0,
      toolX: 0,
      toolY: 0,
      toolWidth: 0,
      toolHeight: 0,
      rawX: x,
      rawY: y,
      toolType: ToolType.FINGER,
    };
    const event: TouchEvent = {
      id: ++this.eventId,
      deviceId: 0,
      actionTime: now,
      screenId: 0,
      windowId: 0,
      action: action,
      touch: touch,
      touches: [touch],
      sourceType: SourceType.TOUCH_SCREEN,
    } as TouchEvent;
    try {
      inputEventClient.injectTouchEvent({ touchEvent: event });
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'inject touch: %{public}s', JSON.stringify(e));
    }
  }

  private injectKey(keyCode: number): void {
    setTimeout(() => {
      this.injectSingleKey(keyCode, true);
    }, 0);
    setTimeout(() => {
      this.injectSingleKey(keyCode, false);
    }, 50);
  }

  private injectSingleKey(keyCode: number, isPressed: boolean): void {
    const keyData: SimpleKeyEvent = {
      isPressed: isPressed,
      keyCode: keyCode,
      keyDownDuration: 0,
      isIntercepted: false,
    };
    try {
      inputEventClient.injectKeyEvent({ keyEvent: keyData });
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'injectKeyEvent FAIL kc=%{public}d err=%{public}s',
        keyCode, JSON.stringify(e));
    }
  }

  private adjustBrightness(up: boolean): void {
    try {
      this.currentBrightness = Math.max(0, Math.min(255,
        this.currentBrightness + (up ? 32 : -32)));
      brightness.setValue(this.currentBrightness);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'brightness: %{public}s', JSON.stringify(e));
    }
  }

  private handleMouseEvent(payload: Uint8Array): void {
    if (payload.byteLength < 14) return;
    const view = new DataView(payload.buffer, payload.byteOffset, payload.byteLength);
    const action: number = view.getUint8(0);
    const button: number = view.getUint8(1);
    const rawX: number = view.getUint32(2, false);
    const rawY: number = view.getUint32(6, false);
    const axisValue: number = view.getFloat32(10, false);

    let x: number = rawX;
    let y: number = rawY;
    if (this.streamWidth > 0 && this.streamHeight > 0 &&
        this.realWidth > 0 && this.realHeight > 0) {
      x = Math.round(rawX * this.realWidth / this.streamWidth);
      y = Math.round(rawY * this.realHeight / this.streamHeight);
    }
    x = Math.max(0, Math.min(this.realWidth > 0 ? this.realWidth - 1 : x, x));
    y = Math.max(0, Math.min(this.realHeight > 0 ? this.realHeight - 1 : y, y));

    const axes: AxisValue[] = [];
    if (action === MouseAction.AXIS_UPDATE) {
      const av: AxisValue = { axis: Axis.SCROLL_VERTICAL, value: axisValue };
      axes.push(av);
    }

    const pressedButtons: MouseButton[] = [];
    if (action === MouseAction.BUTTON_DOWN) {
      pressedButtons.push(button as MouseButton);
    }

    const now: number = Date.now();
    const event: MouseEvent = {
      id: ++this.eventId,
      deviceId: 0,
      actionTime: now,
      screenId: 0,
      windowId: 0,
      action: action as MouseAction,
      screenX: x,
      screenY: y,
      windowX: x,
      windowY: y,
      rawDeltaX: 0,
      rawDeltaY: 0,
      button: button as MouseButton,
      pressedButtons: pressedButtons,
      axes: axes,
      pressedKeys: [],
      ctrlKey: false,
      altKey: false,
      shiftKey: false,
      logoKey: false,
      fnKey: false,
      capsLock: false,
      numLock: false,
      scrollLock: false,
      toolType: MouseToolType.MOUSE,
    } as MouseEvent;

    setTimeout(() => {
      try {
        inputEventClient.injectMouseEvent({ mouseEvent: event });
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'injectMouseEvent: %{public}s', JSON.stringify(e));
      }
    }, 0);
  }

  private handleKeyEvent(payload: Uint8Array): void {
    if (payload.byteLength < 5) return;
    const view = new DataView(payload.buffer, payload.byteOffset, payload.byteLength);
    const isPressed: boolean = view.getUint8(0) !== 0;
    const keyCode: number = view.getUint32(1, false);
    setTimeout(() => {
      this.injectSingleKey(keyCode, isPressed);
    }, 0);
  }

  private handleTextInput(payload: Uint8Array): void {
    const decoder = new util.TextDecoder('utf-8');
    const text: string = decoder.decodeToString(payload);
    if (text.length === 0) return;
    const pasteData: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
    const board: pasteboard.SystemPasteboard = pasteboard.getSystemPasteboard();
    board.setData(pasteData).then(() => {
      this.injectSingleKey(KeyCode.KEYCODE_CTRL_LEFT, true);
      setTimeout(() => {
        this.injectSingleKey(KeyCode.KEYCODE_V, true);
        setTimeout(() => {
          this.injectSingleKey(KeyCode.KEYCODE_V, false);
          this.injectSingleKey(KeyCode.KEYCODE_CTRL_LEFT, false);
        }, 20);
      }, 20);
    }).catch((e: Error) => {
      hilog.warn(DOMAIN, TAG, 'clipboard setData failed: %{public}s', e.message ?? JSON.stringify(e));
    });
  }

  private adjustVolume(up: boolean): void {
    const group = this.volumeGroup;
    if (!group) {
      hilog.warn(DOMAIN, TAG, 'volume: group not initialized');
      return;
    }
    // 用 AudioStreamManager.isActiveSync 判断 MEDIA 流是否在播放：
    // - 有音乐/视频在播 → 调 MEDIA，跟物理键一致；
    // - 否则回退到 RINGTONE（铃声/通知），保证音量条 UI 仍然显示。
    // getActiveVolumeTypeSync 是 API 13+，API 12 无法用，故走 isActiveSync。
    let streamType: audio.AudioVolumeType = audio.AudioVolumeType.RINGTONE;
    try {
      const sm = this.streamMgr;
      if (sm && sm.isActiveSync(audio.AudioVolumeType.MEDIA)) {
        streamType = audio.AudioVolumeType.MEDIA;
      }
    } catch (e) {
      const err = e as Error;
      hilog.warn(DOMAIN, TAG, 'isActiveSync failed: %{public}s, fallback to RINGTONE',
        err.message ?? JSON.stringify(e));
    }
    const finalType = streamType;
    group.getVolume(finalType).then((cur: number) => {
      return group.getMaxVolume(finalType).then((max: number) => {
        const next = Math.max(0, Math.min(max, cur + (up ? 1 : -1)));
        hilog.info(DOMAIN, TAG, 'setVolumeWithFlag type=%{public}d cur=%{public}d max=%{public}d next=%{public}d',
          finalType, cur, max, next);
        // flags=1 (FLAG_SHOW_SYSTEM_UI) 拉起系统音量条
        return group.setVolumeWithFlag(finalType, next, 1);
      });
    }).catch((e: Error) => {
      hilog.warn(DOMAIN, TAG, 'setVolumeWithFlag failed: %{public}s', e.message ?? JSON.stringify(e));
    });
  }
}
