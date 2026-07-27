import { common, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import { zlib } from '@kit.BasicServicesKit';
import installer from '@ohos.bundle.installer';
import { BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { image } from '@kit.ImageKit';
import { promptAction } from '@kit.ArkUI';

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
  mainElement: string;
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

/** 卡片最大宽度（横屏居中） */
const CARD_MAX_WIDTH: number = 520;
/** 权限列表最大高度 */
const PERM_LIST_MAX_HEIGHT: number = 260;

@Entry(storage)
@Component
struct HapInstallPage {
  @LocalStorageProp('hapUri') hapUri: string = '';
  @LocalStorageProp('installDisabled') installDisabled: boolean = false;
  @State installState: InstallState = 'confirm';
  @State displayName: string = '';
  @State bundleName: string = '';
  @State mainElement: string = '';
  @State versionName: string = '';
  @State permissions: Array<string> = [];
  @State errorMessage: string = '';
  @State iconPixelMap: image.PixelMap | null = null;
  @State hapFilePath: string = '';
  @State showPermissions: boolean = false;
  private tempDir: string = '';

  aboutToAppear(): void {
    if (this.installDisabled) {
      // 系统禁止安装，弹出提示后退出
      promptAction.showDialog({
        title: '提示',
        message: '不支持安装应用程序',
        buttons: [
          { text: '确定', color: '#007DFF' }
        ]
      }).then(() => {
        this.closeSelf();
      });
      return;
    }
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
      this.mainElement = hapJson.module.mainElement ?? '';
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
      abilityName: this.mainElement
    };
    ctx.startAbility(want).then(() => {
      ctx.terminateSelf();
    }).catch((err: BusinessError) => {
      hilog.error(DOMAIN, TAG, 'openApp failed: %{public}s', JSON.stringify(err));
      ctx.terminateSelf();
    });
  }

  private togglePermissions(): void {
    this.showPermissions = !this.showPermissions;
  }

  build() {
    Stack() {
      if (!this.installDisabled) {
        // 底层：浅灰背景（横屏两边留白区域）
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('#F2F3F5')

        // 居中白色卡片
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
        .alignItems(HorizontalAlign.Center)
        .padding({ left: 24, right: 24 })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F2F3F5')
  }

  @Builder
  buildConfirm() {
    Column() {
      // 卡片
      Column() {
        // ---- 图标 ----
        if (this.iconPixelMap !== null) {
          Image(this.iconPixelMap)
            .width(72)
            .height(72)
            .borderRadius(16)
            .margin({ bottom: 16 })
        } else {
          Image($r('app.media.startIcon'))
            .width(72)
            .height(72)
            .borderRadius(16)
            .margin({ bottom: 16 })
        }

        // ---- 应用名 ----
        Text(this.displayName)
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor('#1A1A1A')
          .textAlign(TextAlign.Center)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ bottom: 4 })

        // ---- 包名 ----
        if (this.bundleName.length > 0) {
          Text(this.bundleName)
            .fontSize(12)
            .fontColor('#999999')
            .fontFamily('monospace')
            .textAlign(TextAlign.Center)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ bottom: 20 })
        }

        // ---- 分割线 ----
        Divider()
          .strokeWidth(1)
          .color('#EEEEEE')
          .margin({ bottom: 16 })

        // ---- 权限区域 ----
        Column() {
          Row() {
            Text('当前应用申请权限 ' + this.permissions.length.toString() + ' 个')
              .fontSize(13)
              .fontColor('#555555')
              .fontWeight(FontWeight.Medium)
              .layoutWeight(1)

            Text(this.showPermissions ? '收起 ▲' : '展开 ▼')
              .fontSize(12)
              .fontColor('#007DFF')
              .onClick(() => {
                this.togglePermissions();
              })
          }
          .width('100%')
          .padding({ top: 4, bottom: this.showPermissions ? 8 : 4 })
          .onClick(() => {
            this.togglePermissions();
          })

          if (this.showPermissions) {
            if (this.permissions.length === 0) {
              Text('无需任何权限')
                .fontSize(12)
                .fontColor('#999999')
                .width('100%')
                .padding({ left: 4 })
            } else {
              List() {
                ForEach(this.permissions, (perm: string) => {
                  ListItem() {
                    Row() {
                      Text('•')
                        .fontSize(14)
                        .fontColor('#007DFF')
                        .margin({ right: 8 })

                      Text(perm)
                        .fontSize(12)
                        .fontColor('#333333')
                        .fontFamily('monospace')
                        .layoutWeight(1)
                    }
                    .width('100%')
                    .padding({ top: 5, bottom: 5 })
                  }
                })
              }
              .width('100%')
              .constraintSize({ maxHeight: PERM_LIST_MAX_HEIGHT })
              .scrollBar(BarState.Auto)
              .backgroundColor('#F8F9FA')
              .borderRadius(8)
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            }
          }
        }
        .width('100%')

        // ---- 按钮区 ----
        Row({ space: 12 }) {
          Button('取消')
            .layoutWeight(1)
            .height(42)
            .backgroundColor('#F0F0F0')
            .fontColor('#555555')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .borderRadius(8)
            .onClick(() => {
              this.closeSelf();
            })

          Button('安装')
            .layoutWeight(1)
            .height(42)
            .backgroundColor('#007DFF')
            .fontColor('#FFFFFF')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .borderRadius(8)
            .onClick(() => {
              this.doInstall();
            })
        }
        .width('100%')
        .margin({ top: 20 })
      }
      .width('100%')
      .constraintSize({ maxWidth: CARD_MAX_WIDTH })
      .backgroundColor('#FFFFFF')
      .borderRadius(16)
      .padding({ left: 28, right: 28, top: 36, bottom: 28 })
      .shadow({
        radius: 16,
        color: '#00000010',
        offsetY: 4
      })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  buildInstalling() {
    Column() {
      Column() {
        LoadingProgress()
          .width(52)
          .height(52)
          .color('#007DFF')
          .margin({ bottom: 20 })

        Text('正在安装…')
          .fontSize(16)
          .fontColor('#333333')
          .fontWeight(FontWeight.Medium)
      }
      .width('100%')
      .constraintSize({ maxWidth: CARD_MAX_WIDTH })
      .backgroundColor('#FFFFFF')
      .borderRadius(16)
      .padding({ left: 28, right: 28, top: 48, bottom: 48 })
      .alignItems(HorizontalAlign.Center)
      .shadow({
        radius: 16,
        color: '#00000010',
        offsetY: 4
      })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  buildSuccess() {
    Column() {
      Column() {
        Column() {
          Image($r('app.media.ic_success'))
            .width(56)
            .height(56)
            .margin({ bottom: 12 })

          Text('安装成功')
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor('#1A1A1A')
            .margin({ bottom: 4 })

          Text(this.displayName)
            .fontSize(13)
            .fontColor('#888888')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ bottom: 28 })
        }
        .alignItems(HorizontalAlign.Center)

        Row({ space: 12 }) {
          Button('关闭')
            .layoutWeight(1)
            .height(42)
            .backgroundColor('#F0F0F0')
            .fontColor('#555555')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .borderRadius(8)
            .onClick(() => {
              this.closeSelf();
            })

          Button('打开应用')
            .layoutWeight(1)
            .height(42)
            .backgroundColor('#007DFF')
            .fontColor('#FFFFFF')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .borderRadius(8)
            .onClick(() => {
              this.openApp();
            })
        }
        .width('100%')
      }
      .width('100%')
      .constraintSize({ maxWidth: CARD_MAX_WIDTH })
      .backgroundColor('#FFFFFF')
      .borderRadius(16)
      .padding({ left: 28, right: 28, top: 36, bottom: 28 })
      .shadow({
        radius: 16,
        color: '#00000010',
        offsetY: 4
      })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  buildFailed() {
    Column() {
      Column() {
        Column() {
          Image($r('app.media.ic_fail'))
            .width(56)
            .height(56)
            .margin({ bottom: 12 })

          Text('安装失败')
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor('#1A1A1A')
            .margin({ bottom: 4 })

          Text(this.displayName)
            .fontSize(13)
            .fontColor('#888888')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ bottom: 20 })
        }
        .alignItems(HorizontalAlign.Center)

        Text(this.errorMessage)
          .fontSize(12)
          .fontColor('#E05555')
          .textAlign(TextAlign.Center)
          .width('100%')
          .padding({ top: 14, bottom: 14, left: 16, right: 16 })
          .backgroundColor('#FFF5F5')
          .borderRadius(8)
          .margin({ bottom: 20 })

        Button('关闭')
          .width('100%')
          .height(42)
          .backgroundColor('#F0F0F0')
          .fontColor('#555555')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .borderRadius(8)
          .onClick(() => {
            this.closeSelf();
          })
      }
      .width('100%')
      .constraintSize({ maxWidth: CARD_MAX_WIDTH })
      .backgroundColor('#FFFFFF')
      .borderRadius(16)
      .padding({ left: 28, right: 28, top: 36, bottom: 28 })
      .shadow({
        radius: 16,
        color: '#00000010',
        offsetY: 4
      })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
  }
}
