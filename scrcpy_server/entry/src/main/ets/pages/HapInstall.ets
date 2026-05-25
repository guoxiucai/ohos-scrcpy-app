import { common, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { fileIo } from '@kit.CoreFileKit';
import { zlib } from '@kit.BasicServicesKit';
import installer from '@ohos.bundle.installer';
import { BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';

const DOMAIN: number = 0xA001;
const TAG: string = 'HapInstall';

interface PermissionItem {
  name: string;
}

interface ModuleJson {
  module: ModuleInfo;
}

interface ModuleInfo {
  name: string;
  requestPermissions: Array<PermissionItem>;
}

interface AppJson {
  app: AppInfo;
}

interface AppInfo {
  bundleName: string;
  versionName: string;
  versionCode: number;
}

type InstallState = 'confirm' | 'installing' | 'success' | 'failed';

const storage = LocalStorage.getShared();

@Entry(storage)
@Component
struct HapInstallPage {
  @LocalStorageProp('hapUri') hapUri: string = '';
  @LocalStorageProp('context') abilityContext: common.UIAbilityContext | null = null;
  @State installState: InstallState = 'confirm';
  @State bundleName: string = '';
  @State versionName: string = '';
  @State permissions: Array<string> = [];
  @State errorMessage: string = '';
  @State hapFilePath: string = '';
  private tempDir: string = '';

  aboutToAppear(): void {
    this.parseHap();
  }

  private async parseHap(): Promise<void> {
    try {
      const ctx: common.UIAbilityContext = this.abilityContext as common.UIAbilityContext;
      this.tempDir = ctx.tempDir + '/hap_extract_' + Date.now().toString();
      const uri: string = this.hapUri;
      let filePath: string = '';
      if (uri.startsWith('file://')) {
        filePath = uri.replace('file://', '');
      } else {
        filePath = uri;
      }
      this.hapFilePath = filePath;
      await fileIo.mkdir(this.tempDir);
      const options: zlib.Options = {};
      await zlib.decompressFile(filePath, this.tempDir, options);
      const moduleJsonPath: string = this.tempDir + '/module.json5';
      const moduleExists: boolean = fileIo.accessSync(moduleJsonPath);
      if (!moduleExists) {
        this.errorMessage = '不是有效的 HAP 文件（缺少 module.json5）';
        this.installState = 'failed';
        return;
      }
      const moduleContent: string = await this.readFileAsString(moduleJsonPath);
      const moduleJson: ModuleJson = JSON.parse(moduleContent) as ModuleJson;
      const permList: Array<PermissionItem> = moduleJson.module.requestPermissions ?? [];
      const permNames: Array<string> = [];
      for (let i: number = 0; i < permList.length; i++) {
        permNames.push(permList[i].name);
      }
      this.permissions = permNames;

      const appJsonPath: string = this.tempDir + '/app.json5';
      const appExists: boolean = fileIo.accessSync(appJsonPath);
      if (appExists) {
        const appContent: string = await this.readFileAsString(appJsonPath);
        const appJson: AppJson = JSON.parse(appContent) as AppJson;
        this.bundleName = appJson.app.bundleName ?? '';
        this.versionName = appJson.app.versionName ?? '';
      } else {
        this.bundleName = moduleJson.module.name ?? '未知';
        this.versionName = '';
      }
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'parseHap failed: %{public}s', JSON.stringify(err));
      this.errorMessage = '文件无法解析';
      this.installState = 'failed';
    }
  }

  private async readFileAsString(path: string): Promise<string> {
    const file: fileIo.File = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
    const stat: fileIo.Stat = fileIo.statSync(path);
    const buf: ArrayBuffer = new ArrayBuffer(stat.size);
    fileIo.readSync(file.fd, buf);
    fileIo.closeSync(file);
    const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
    const uint8: Uint8Array = new Uint8Array(buf);
    return decoder.decodeToString(uint8);
  }

  private async doInstall(): Promise<void> {
    this.installState = 'installing';
    try {
      const bundleInstaller: installer.BundleInstaller = await installer.getBundleInstaller();
      const installParam: installer.InstallParam = {
        installFlag: 1,
        isKeepData: false
      };
      bundleInstaller.install([this.hapFilePath], installParam, (err: BusinessError) => {
        if (err) {
          hilog.error(DOMAIN, TAG, 'install failed: %{public}s', JSON.stringify(err));
          this.errorMessage = '安装失败：' + err.message + ' (code: ' + err.code.toString() + ')';
          this.installState = 'failed';
        } else {
          hilog.info(DOMAIN, TAG, 'install success');
          this.installState = 'success';
        }
        this.cleanTemp();
      });
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'doInstall exception: %{public}s', JSON.stringify(err));
      this.errorMessage = '安装异常：' + JSON.stringify(err);
      this.installState = 'failed';
      this.cleanTemp();
    }
  }

  private cleanTemp(): void {
    try {
      fileIo.rmdirSync(this.tempDir);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'cleanTemp failed: %{public}s', JSON.stringify(err));
    }
  }

  private closeSelf(): void {
    const ctx: common.UIAbilityContext = this.abilityContext as common.UIAbilityContext;
    ctx.terminateSelf();
  }

  private openApp(): void {
    const ctx: common.UIAbilityContext = this.abilityContext as common.UIAbilityContext;
    const want: Want = {
      bundleName: this.bundleName,
      abilityName: 'MainAbility'
    };
    ctx.startAbility(want).then(() => {
      ctx.terminateSelf();
    }).catch((err: BusinessError) => {
      hilog.error(DOMAIN, TAG, 'openApp failed: %{public}s', JSON.stringify(err));
      ctx.terminateSelf();
    });
  }

  build() {
    Column() {
      if (this.installState === 'confirm') {
        this.buildConfirm();
      } else if (this.installState === 'installing') {
        this.buildInstalling();
      } else if (this.installState === 'success') {
        this.buildSuccess();
      } else {
        this.buildFailed();
      }
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .padding(24)
  }

  @Builder
  buildConfirm() {
    Column({ space: 16 }) {
      Image($r('app.media.startIcon'))
        .width(64)
        .height(64)

      Text(this.bundleName)
        .fontSize(18)
        .fontWeight(FontWeight.Bold)

      if (this.versionName.length > 0) {
        Text('版本：' + this.versionName)
          .fontSize(14)
          .fontColor('#666666')
      }

      Column({ space: 8 }) {
        Text('申请的权限：')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .alignSelf(ItemAlign.Start)

        if (this.permissions.length === 0) {
          Text('无')
            .fontSize(13)
            .fontColor('#999999')
            .alignSelf(ItemAlign.Start)
        } else {
          List() {
            ForEach(this.permissions, (perm: string) => {
              ListItem() {
                Text('• ' + perm)
                  .fontSize(13)
                  .fontColor('#333333')
              }
            })
          }
          .width('100%')
          .layoutWeight(1)
        }
      }
      .width('100%')
      .layoutWeight(1)
      .padding({ top: 16 })

      Row({ space: 16 }) {
        Button('取消')
          .width('40%')
          .height(40)
          .backgroundColor('#E0E0E0')
          .fontColor('#333333')
          .onClick(() => {
            this.closeSelf();
          })

        Button('安装')
          .width('40%')
          .height(40)
          .backgroundColor('#007DFF')
          .fontColor('#FFFFFF')
          .onClick(() => {
            this.doInstall();
          })
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  buildInstalling() {
    Column({ space: 16 }) {
      LoadingProgress()
        .width(48)
        .height(48)

      Text('正在安装...')
        .fontSize(16)
    }
  }

  @Builder
  buildSuccess() {
    Column({ space: 16 }) {
      Text('✓')
        .fontSize(48)
        .fontColor('#4CAF50')

      Text('安装成功')
        .fontSize(18)
        .fontWeight(FontWeight.Bold)

      Row({ space: 16 }) {
        Button('关闭')
          .width('40%')
          .height(40)
          .backgroundColor('#E0E0E0')
          .fontColor('#333333')
          .onClick(() => {
            this.closeSelf();
          })

        Button('打开')
          .width('40%')
          .height(40)
          .backgroundColor('#007DFF')
          .fontColor('#FFFFFF')
          .onClick(() => {
            this.openApp();
          })
      }
    }
  }

  @Builder
  buildFailed() {
    Column({ space: 16 }) {
      Text('✗')
        .fontSize(48)
        .fontColor('#F44336')

      Text('安装失败')
        .fontSize(18)
        .fontWeight(FontWeight.Bold)

      Text(this.errorMessage)
        .fontSize(13)
        .fontColor('#666666')
        .textAlign(TextAlign.Center)

      Button('关闭')
        .width('40%')
        .height(40)
        .backgroundColor('#E0E0E0')
        .fontColor('#333333')
        .onClick(() => {
          this.closeSelf();
        })
    }
  }
}
