import { common, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import { zlib } from '@kit.BasicServicesKit';
import installer from '@ohos.bundle.installer';
import { BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { image } from '@kit.ImageKit';

const DOMAIN: number = 0xA001;
const TAG: string = 'HapInstall';

interface PermissionItem {
  name: string;
}

interface HapJson {
  app: AppInfo;
  module: ModuleInfo;
}

interface ModuleInfo {
  name: string;
  requestPermissions: Array<PermissionItem>;
}

interface AppInfo {
  bundleName: string;
  icon: string;
  versionName: string;
  versionCode: number;
}

type InstallState = 'confirm' | 'installing' | 'success' | 'failed';

const storage = LocalStorage.getShared();

@Entry(storage)
@Component
struct HapInstallPage {
  @LocalStorageProp('hapUri') hapUri: string = '';
  @State installState: InstallState = 'confirm';
  @State displayName: string = '';
  @State bundleName: string = '';
  @State versionName: string = '';
  @State permissions: Array<string> = [];
  @State errorMessage: string = '';
  @State iconPixelMap: image.PixelMap | null = null;
  @State hapFilePath: string = '';
  private tempDir: string = '';

  aboutToAppear(): void {
    this.parseHap();
  }

  private getFileNameWithoutExt(uri: string): string {
    let name: string = uri;
    const slashIdx: number = name.lastIndexOf('/');
    if (slashIdx >= 0) {
      name = name.substring(slashIdx + 1);
    }
    name = decodeURIComponent(name);
    if (name.toLowerCase().endsWith('.hap')) {
      name = name.substring(0, name.length - 4);
    }
    return name;
  }

  private async parseHap(): Promise<void> {
    try {
      const uri: string = this.hapUri;
      const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      this.tempDir = ctx.tempDir + '/hap_extract_' + Date.now().toString();
      const fileName: string = this.getFileNameWithoutExt(uri);

      let filePath: string = '';
      if (uri.startsWith('file://')) {
        const fileUriObj = new fileUri.FileUri(uri);
        filePath = fileUriObj.path;
      } else {
        filePath = uri;
      }
      this.hapFilePath = filePath;
      hilog.info(DOMAIN, TAG, 'hapFilePath: %{public}s', filePath);

      await fileIo.mkdir(this.tempDir);
      await zlib.decompressFile(filePath, this.tempDir, {} as zlib.Options);
      hilog.info(DOMAIN, TAG, 'decompress done');

      const moduleJsonPath: string = this.tempDir + '/module.json';
      if (!fileIo.accessSync(moduleJsonPath)) {
        this.errorMessage = '不是有效的 HAP 文件（缺少 module.json）';
        this.installState = 'failed';
        return;
      }

      const content: string = await this.readFileAsString(moduleJsonPath);
      const hapJson: HapJson = JSON.parse(content) as HapJson;

      this.bundleName = hapJson.app.bundleName ?? '';
      this.versionName = hapJson.app.versionName ?? '';
      this.displayName = this.versionName.length > 0 ? `${fileName}(${this.versionName})` : fileName;
      hilog.info(DOMAIN, TAG, 'displayName: %{public}s, bundleName: %{public}s', this.displayName, this.bundleName);

      const permList: Array<PermissionItem> = hapJson.module.requestPermissions ?? [];
      const permNames: Array<string> = [];
      for (let i: number = 0; i < permList.length; i++) {
        permNames.push(permList[i].name);
      }
      this.permissions = permNames;

      const iconRef: string = hapJson.app.icon ?? '';
      if (iconRef.length > 0) {
        let iconName: string = iconRef;
        if (iconName.startsWith('$media:')) {
          iconName = iconName.substring(7);
        }
        const iconPath: string = this.tempDir + '/resources/base/media/' + iconName + '.png';
        hilog.info(DOMAIN, TAG, 'icon path: %{public}s', iconPath);
        if (fileIo.accessSync(iconPath)) {
          const iconFile: fileIo.File = fileIo.openSync(iconPath, fileIo.OpenMode.READ_ONLY);
          const imageSource: image.ImageSource = image.createImageSource(iconFile.fd);
          this.iconPixelMap = await imageSource.createPixelMap();
          fileIo.closeSync(iconFile);
          hilog.info(DOMAIN, TAG, 'icon loaded');
        }
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
    const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    ctx.terminateSelf();
  }

  private openApp(): void {
    const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
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
      if (this.iconPixelMap !== null) {
        Image(this.iconPixelMap)
          .width(64)
          .height(64)
      } else {
        Image($r('app.media.startIcon'))
          .width(64)
          .height(64)
      }

      Text(this.displayName)
        .fontSize(18)
        .fontWeight(FontWeight.Bold)

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
