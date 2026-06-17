import { UIAbility, Want, AbilityConstant } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import systemParameterEnhance from '@ohos.systemParameterEnhance';

const DOMAIN: number = 0xA001;
const TAG: string = 'HapInstallerAbility';
const PROP_KEY: string = 'persist.sys.installapk.enable';

export default class HapInstallerAbility extends UIAbility {
  private hapUri: string = '';
  private installDisabled: boolean = false;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'onCreate, want uri: %{public}s', want.uri ?? '');
    this.hapUri = want.uri ?? '';

    // 检查系统属性，判断是否允许安装（读取失败时默认禁止安装）
    try {
      const enabled: string = systemParameterEnhance.getSync(PROP_KEY, 'false');
      this.installDisabled = enabled.toLowerCase() !== 'true';
      hilog.info(DOMAIN, TAG, 'install check: %{public}s=%{public}s, disabled=%{public}s',
        PROP_KEY, enabled, this.installDisabled.toString());
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'getSync failed: %{public}s, block install', JSON.stringify(err));
      this.installDisabled = true;
    }
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'onNewWant, want uri: %{public}s', want.uri ?? '');
    this.hapUri = want.uri ?? '';
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    const storage: LocalStorage = new LocalStorage();
    storage.setOrCreate<string>('hapUri', this.hapUri);
    storage.setOrCreate<object>('context', this.context);
    storage.setOrCreate<boolean>('installDisabled', this.installDisabled);
    windowStage.loadContent('pages/HapInstall', storage, (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'loadContent failed: %{public}s', JSON.stringify(err));
      }
    });
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'onDestroy');
  }

  onForeground(): void {}
  onBackground(): void {}
}
