import i18n from '@ohos.i18n';

export type AppLanguage = 'system' | 'zh-CN' | 'en-US';

/** Translates the app's own UI; clipboard content and server file names stay untouched. */
export class LocalizationUtil {
  private static readonly chinese: Record<string, string> = {
    'Home': '首页',
    'History': '历史记录',
    'Browse and save synced items': '浏览和保存同步记录',
    'Settings': '设置',
    'Clipboard overview and quick sync': '查看剪贴板并快速同步',
    'Current Clipboard': '当前剪贴板',
    'The latest clipboard content detected on this device.': '此设备当前的剪贴板内容。',
    'Image': '图片',
    'Text': '文字',
    'File': '文件',
    'Group': '文件组',
    'Upload Text': '上传文字',
    'Only text can be uploaded from this screen.': '此页面目前仅支持上传文字。',
    'Recent Activity': '最近活动',
    'Recent server item and sync controls.': '服务器最近记录与同步控制。',
    'Auto Sync': '自动同步',
    'Sync Now': '立即同步',
    'Latest History': '最新记录',
    '[No preview]': '[暂无预览]',
    '[Preview omitted for large image]': '[大图片不加载预览]',
    '[Image loading...]': '[正在加载图片]',
    '[Image preview unavailable]': '[图片预览不可用]',
    'Updated from history': '来自历史记录',
    'Polling is active': '正在自动同步',
    'Manual sync mode': '手动同步模式',
    'Copy Text': '复制文字',
    'Save File': '保存文件',
    'Save': '保存',
    'Save As': '另存为',
    'No synced history item yet. Tap Sync Now to refresh.': '暂无同步记录，点击“立即同步”刷新。',
    'Loading more...': '正在加载更多…',
    'No more items': '没有更多记录',
    'No history items': '暂无历史记录',
    'Uploading...': '正在上传…',
    'Upload Success': '上传成功',
    'Syncing...': '正在同步…',
    'Text synced to clipboard': '文字已同步到剪贴板',
    'File available in Recent Activity': '文件可在最近活动中保存',
    'Copied to clipboard': '已复制到剪贴板',
    'Copy failed': '复制失败',
    'Downloading...': '正在下载…',
    'Saving...': '正在保存…',
    'Saved to selected folder': '已保存到所选文件夹',
    'Save canceled': '已取消保存',
    'Saved to Gallery': '已保存到图库',
    'Tap Save to Gallery': '请点击“保存到图库”',
    'Gallery authorization canceled': '已取消图库授权',
    'Idle': '空闲',
    'Clipboard is empty': '剪贴板为空',
    'Empty clipboard': '剪贴板为空',
    'Clipboard permission denied': '剪贴板读取权限被拒绝',
    '[Image in clipboard]': '[剪贴板中的图片]',
    '[Clipboard data unavailable]': '[剪贴板内容不可用]',
    'Error reading clipboard': '读取剪贴板失败',
    'Current clipboard is not plain text': '当前剪贴板不是纯文字',
    'Server Connection': '服务器连接',
    'Connect to your SyncClipboard server.': '连接你的 SyncClipboard 服务器。',
    'Preferences': '偏好设置',
    'Choose how ClipLink looks and syncs.': '选择云剪的外观和同步方式。',
    'Manage your server and app preferences.': '管理服务器连接和应用偏好。',
    'Server URL': '服务器地址',
    'Username': '用户名',
    'Password': '密码',
    'Save Connection': '保存连接',
    'Polling Interval': '轮询间隔',
    'How often the app pulls from the server when auto sync is enabled.': '开启自动同步后，从服务器读取的时间间隔（秒）。',
    'Theme': '主题',
    'Applies immediately, including dark mode.': '选择后立即生效。',
    'Light': '浅色',
    'Dark': '深色',
    'Auto': '跟随系统',
    'Language': '语言',
    'Choose the language used on these pages.': '选择应用页面使用的语言。',
    'System': '跟随系统',
    'Use Pure Black in Dark': '深色模式使用纯黑背景',
    'Affects Dark mode directly, and Auto mode whenever the system switches to dark.': '深色主题下使用纯黑背景。',
    'Max History Size': '历史记录条数上限',
    'Controls how many recent items stay available locally.': '预留设置；当前版本尚未按此数量清理记录。',
    'Theme updated': '主题已更新',
    'Theme update failed': '主题更新失败',
    'Language updated': '语言已更新',
    'Language update failed': '语言更新失败',
    'Pure black enabled': '已开启纯黑背景',
    'Pure black disabled': '已关闭纯黑背景',
    'Saved successfully': '保存成功',
    'Checking connection...': '正在检查连接…',
    'Connected': '已连接',
    'Saved, but connection failed': '已保存，但连接失败',
    'Save failed': '保存失败'
  };

  static systemLanguage(): string {
    try {
      return i18n.System.getSystemLanguage();
    } catch (_) {
      return 'en';
    }
  }

  static isChinese(language: string, systemLanguage: string): boolean {
    return language === 'zh-CN' || (language === 'system' && systemLanguage.toLowerCase().startsWith('zh'));
  }

  static text(value: string, language: string, systemLanguage: string): string {
    if (!LocalizationUtil.isChinese(language, systemLanguage)) {
      return value;
    }
    const exact = LocalizationUtil.chinese[value];
    if (exact) {
      return exact;
    }
    const prefixes: string[][] = [
      ['Upload Error: ', '上传失败：'],
      ['Sync Error: ', '同步失败：'],
      ['Copy Error: ', '复制失败：'],
      ['Save Error: ', '保存失败：'],
      ['Save failed: ', '保存失败：'],
      ['Saved to Download/', '已保存到 Download/']
    ];
    for (const pair of prefixes) {
      if (value.startsWith(pair[0])) {
        return pair[1] + value.slice(pair[0].length);
      }
    }
    return value;
  }

  static formatBytes(bytes: number): string {
    if (bytes < 1024) return `${Math.max(0, Math.floor(bytes))} B`;
    if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KiB`;
    if (bytes < 1024 * 1024 * 1024) return `${(bytes / (1024 * 1024)).toFixed(1)} MiB`;
    return `${(bytes / (1024 * 1024 * 1024)).toFixed(1)} GiB`;
  }
}
