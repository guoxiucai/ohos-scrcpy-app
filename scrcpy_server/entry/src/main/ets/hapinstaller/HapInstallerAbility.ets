import { UIAbility, Want, AbilityConstant } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0xA001;
const TAG: string = 'HapInstallerAbility';

export default class HapInstallerAbility extends UIAbility {
  private hapUri: string = '';

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'onCreate, want uri: %{public}s', want.uri ?? '');
    this.hapUri = want.uri ?? '';
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'onNewWant, want uri: %{public}s', want.uri ?? '');
    this.hapUri = want.uri ?? '';
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    const storage: LocalStorage = new LocalStorage();
    storage.setOrCreate<string>('hapUri', this.hapUri);
    storage.setOrCreate<object>('context', this.context);
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
