import bundleManager from '@ohos.bundle.bundleManager';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppEntry, encodeAppList } from './Protocol';

const DOMAIN = 0xA000;
const TAG = 'AppListProvider';

export class AppListProvider {
  /**
   * 拉取所有 removable=true 的应用，按 label / bundle 升序。
   * 失败时返回空数组（不抛），由调用方编 0x20/0x10 包发空列表。
   */
  static async listRemovableApps(): Promise<AppEntry[]> {
    try {
      const flags = bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION;
      const list = await bundleManager.getAllBundleInfo(flags);
      const out: AppEntry[] = [];
      for (let i = 0; i < list.length; i++) {
        const bi = list[i];
        const app = bi.appInfo;
        if (!app) continue;
        if (app.removable !== true) continue;
        const entry: AppEntry = {
          bundle: bi.name,
          label: app.label ?? '',
        };
        out.push(entry);
      }
      out.sort((a: AppEntry, b: AppEntry): number => {
        const la = a.label.length > 0 ? a.label : a.bundle;
        const lb = b.label.length > 0 ? b.label : b.bundle;
        if (la < lb) return -1;
        if (la > lb) return 1;
        return 0;
      });
      hilog.info(DOMAIN, TAG, 'listRemovableApps total=%{public}d removable=%{public}d',
        list.length, out.length);
      return out;
    } catch (e) {
      const err = e as Error;
      hilog.error(DOMAIN, TAG, 'listRemovableApps fail: %{public}s', err.message ?? JSON.stringify(e));
      return [];
    }
  }

  /** 拉列表并编成 AppList 设备状态 payload (含 subType=0x10)。 */
  static async buildAppListPayload(): Promise<Uint8Array> {
    const apps = await AppListProvider.listRemovableApps();
    return encodeAppList(apps);
  }
}
