// Строки таблиц GUI с уведомлением об изменениях (INotifyPropertyChanged). C# 5.
using System;
using System.ComponentModel;

namespace IPADredd.Gui
{
    public abstract class Bindable : INotifyPropertyChanged
    {
        public event PropertyChangedEventHandler PropertyChanged;
        protected void Set<T>(ref T field, T value, string name)
        {
            if (Equals(field, value)) { return; }
            field = value;
            PropertyChangedEventHandler h = PropertyChanged;
            if (h != null) { h(this, new PropertyChangedEventArgs(name)); }
        }
        protected void OnChanged(string name)
        {
            PropertyChangedEventHandler h = PropertyChanged;
            if (h != null) { h(this, new PropertyChangedEventArgs(name)); }
        }
    }

    public class QueueItem : Bindable
    {
        private string _status = "Queued", _statusText = "", _fileName = "", _filePath = "", _error = "", _versionText = "", _progressText = "";
        private double _progress;
        private bool _indeterminate, _showProgress;
        public string Id { get; set; }
        public string AppId { get; set; }
        public string AppName { get; set; }
        public string VersionId { get; set; }
        public bool Purchase { get; set; }
        public string TaskId { get; set; }
        // Ключ ошибки ядра (Err.*) и исходный текст — для статуса в библиотеке покупок.
        public string ErrorKey { get; set; }
        public string ErrorMessage { get; set; }
        // Установить после загрузки: UDID и имя устройства; AccountKey — для сохранения очереди.
        public string InstallUdid { get; set; }
        public string InstallDevice { get; set; }
        public string AccountKey { get; set; }
        public string VersionText { get { return _versionText; } set { Set(ref _versionText, value, "VersionText"); } }
        public string Status { get { return _status; } set { Set(ref _status, value, "Status"); } }
        public string StatusText { get { return _statusText; } set { Set(ref _statusText, value, "StatusText"); } }
        public double Progress { get { return _progress; } set { Set(ref _progress, value, "Progress"); } }
        public string ProgressText { get { return _progressText; } set { Set(ref _progressText, value, "ProgressText"); } }
        public bool IsIndeterminate { get { return _indeterminate; } set { Set(ref _indeterminate, value, "IsIndeterminate"); } }
        public bool ShowProgress { get { return _showProgress; } set { Set(ref _showProgress, value, "ShowProgress"); } }
        public string FileName { get { return _fileName; } set { Set(ref _fileName, value, "FileName"); } }
        public string FilePath { get { return _filePath; } set { Set(ref _filePath, value, "FilePath"); } }
        public string Error { get { return _error; } set { Set(ref _error, value, "Error"); } }
    }

    // Иконки приложений: файл кэша читается один раз (без блокировки, с уменьшением до 64 px) и переиспользуется.
    public static class IconCache
    {
        private static readonly System.Collections.Generic.Dictionary<string, System.Windows.Media.ImageSource> Items =
            new System.Collections.Generic.Dictionary<string, System.Windows.Media.ImageSource>(StringComparer.OrdinalIgnoreCase);
        public static System.Windows.Media.ImageSource Load(string path)
        {
            if (string.IsNullOrEmpty(path)) { return null; }
            System.Windows.Media.ImageSource img;
            if (Items.TryGetValue(path, out img)) { return img; }
            if (!System.IO.File.Exists(path)) { return null; }
            try
            {
                var bmp = new System.Windows.Media.Imaging.BitmapImage();
                bmp.BeginInit();
                bmp.CacheOption = System.Windows.Media.Imaging.BitmapCacheOption.OnLoad;
                bmp.DecodePixelWidth = 64;
                bmp.UriSource = new Uri(path, UriKind.Absolute);
                bmp.EndInit();
                bmp.Freeze();
                img = bmp;
            }
            catch (Exception) { img = null; }
            Items[path] = img;
            return img;
        }
    }

    public class CatalogRow : Bindable
    {
        private string _iconPath;
        private System.Windows.Media.ImageSource _icon;
        public string Initial { get { return string.IsNullOrEmpty(Name) ? "?" : Name.Substring(0, 1).ToUpperInvariant(); } }
        public string IconPath
        {
            get { return _iconPath; }
            set
            {
                if (_iconPath == value) { return; }
                _iconPath = value;
                _icon = IconCache.Load(value);
                OnChanged("IconPath"); OnChanged("Icon"); OnChanged("HasIcon");
            }
        }
        public System.Windows.Media.ImageSource Icon { get { return _icon; } }
        public bool HasIcon { get { return _icon != null; } }
        private string _statusText = "", _version = "";
        public string Name { get; set; }
        public string Id { get; set; }
        public string BundleId { get; set; }
        public string Source { get; set; }
        public string SourceText { get; set; }
        public string PurchaseDate { get; set; }
        public DateTime SortDate { get; set; }
        public string Version { get { return _version; } set { Set(ref _version, value, "Version"); } }
        public string StatusText { get { return _statusText; } set { Set(ref _statusText, value, "StatusText"); } }
    }

    public class LibraryRow : Bindable
    {
        public string Name { get; set; }
        public string BundleId { get; set; }
        public string Version { get; set; }
        public string Build { get; set; }
        public string MinIos { get; set; }
        public string AppStoreId { get; set; }
        public string Artist { get; set; }
        public long SizeBytes { get; set; }
        public string SizeText { get; set; }
        public DateTime Date { get; set; }
        public string DateText { get; set; }
        public string FileName { get; set; }
        public string Path { get; set; }
        public string Error { get; set; }
        public bool HasError { get { return !string.IsNullOrEmpty(Error); } }
        // Подпись: тип (AppStore, AdHoc, ...), текст для таблицы, срок профиля, UDID из профиля.
        public string SignType { get; set; }
        private string _signText = "";
        public string SignText { get { return _signText; } set { Set(ref _signText, value, "SignText"); } }
        public object SignExpires { get; set; }
        public string[] SignDevices { get; set; }
        // Файл вне папки библиотеки (добавлен для установки без копирования).
        public bool IsExternal { get; set; }
    }

    public class DeviceRow : Bindable
    {
        private string _statusText = "";
        public string Name { get; set; }
        public string Model { get; set; }
        public string IosVersion { get; set; }
        public string Udid { get; set; }
        public string ShortUdid { get { return Udid != null && Udid.Length > 16 ? Udid.Substring(0, 8) + "…" + Udid.Substring(Udid.Length - 6) : Udid; } }
        public string Status { get; set; }
        public string Detail { get; set; }
        public string StatusText { get { return _statusText; } set { Set(ref _statusText, value, "StatusText"); } }
        // Подключение: usb | network (Wi-Fi); текст — из локализации.
        private string _connectionText = "";
        public string Connection { get; set; }
        public string ConnectionText { get { return _connectionText; } set { Set(ref _connectionText, value, "ConnectionText"); } }
    }

    public class VersionRow : Bindable
    {
        private string _display = "…", _date = "";
        public int Index { get; set; }
        public string VersionId { get; set; }
        public string DisplayVersion { get { return _display; } set { Set(ref _display, value, "DisplayVersion"); } }
        public string ReleaseDate { get { return _date; } set { Set(ref _date, value, "ReleaseDate"); } }
        public bool Loaded { get; set; }
    }

    public class PurchaseRow : Bindable
    {
        // Строка библиотеки покупок. Status — ключ статуса (Available, Downloaded, UpdateAvailable, NotInStore,
        // Failed, Unverified, Queued, Running) для цвета; тексты задаёт PowerShell (локализация).
        private string _name = "", _artist = "", _status = "", _statusText = "", _statusDetail = "", _versionText = "", _actionText = "", _iconPath, _sizeText = "";
        private double _progress;
        private bool _showProgress, _indeterminate, _actionEnabled = true;
        private System.Windows.Media.ImageSource _icon;
        public string Id { get; set; }
        public string Name { get { return _name; } set { Set(ref _name, value, "Name"); OnChanged("Initial"); } }
        public string Artist { get { return _artist; } set { Set(ref _artist, value, "Artist"); } }
        public string PurchaseDateText { get; set; }
        public DateTime SortDate { get; set; }
        public long SizeBytes { get; set; }
        public string SizeText { get { return _sizeText; } set { Set(ref _sizeText, value, "SizeText"); } }
        public string VersionText { get { return _versionText; } set { Set(ref _versionText, value, "VersionText"); } }
        public string LocalPath { get; set; }
        public string SearchText { get; set; }
        public int StatusOrder { get; set; }
        public string Status { get { return _status; } set { Set(ref _status, value, "Status"); } }
        public string StatusText { get { return _statusText; } set { Set(ref _statusText, value, "StatusText"); } }
        public string StatusDetail { get { return _statusDetail; } set { Set(ref _statusDetail, value, "StatusDetail"); } }
        public string ActionText { get { return _actionText; } set { Set(ref _actionText, value, "ActionText"); } }
        public bool ActionEnabled { get { return _actionEnabled; } set { Set(ref _actionEnabled, value, "ActionEnabled"); } }
        public double Progress { get { return _progress; } set { Set(ref _progress, value, "Progress"); } }
        public bool ShowProgress { get { return _showProgress; } set { Set(ref _showProgress, value, "ShowProgress"); } }
        public bool IsIndeterminate { get { return _indeterminate; } set { Set(ref _indeterminate, value, "IsIndeterminate"); } }
        public string Initial { get { return string.IsNullOrEmpty(_name) ? "?" : _name.Substring(0, 1).ToUpperInvariant(); } }

        // Сравнение с iPhone: DeviceState (Installed, Outdated, Missing, Unknown или пусто), текст колонки и подсказка.
        private string _deviceText = "", _deviceDetail, _deviceState = "";
        private int _deviceOrder = 9;
        public string DeviceState { get { return _deviceState; } set { Set(ref _deviceState, value, "DeviceState"); } }
        public string DeviceText { get { return _deviceText; } set { Set(ref _deviceText, value, "DeviceText"); } }
        public string DeviceDetail { get { return _deviceDetail; } set { Set(ref _deviceDetail, value, "DeviceDetail"); } }
        public int DeviceOrder { get { return _deviceOrder; } set { Set(ref _deviceOrder, value, "DeviceOrder"); } }

        public string IconPath
        {
            get { return _iconPath; }
            set
            {
                if (_iconPath == value) { return; }
                _iconPath = value;
                _icon = IconCache.Load(value);
                OnChanged("IconPath"); OnChanged("Icon"); OnChanged("HasIcon");
            }
        }
        public System.Windows.Media.ImageSource Icon { get { return _icon; } }
        public bool HasIcon { get { return _icon != null; } }
    }

    public class SimpleRow : Bindable
    {
        // Универсальная строка для истории, диагностики и аккаунтов.
        private string _c1 = "", _c2 = "", _c3 = "", _c4 = "", _c5 = "", _c6 = "", _status = "";
        public string C6 { get { return _c6; } set { Set(ref _c6, value, "C6"); } }
        public string Detail { get; set; }
        public string Key { get; set; }
        public string C1 { get { return _c1; } set { Set(ref _c1, value, "C1"); } }
        public string C2 { get { return _c2; } set { Set(ref _c2, value, "C2"); } }
        public string C3 { get { return _c3; } set { Set(ref _c3, value, "C3"); } }
        public string C4 { get { return _c4; } set { Set(ref _c4, value, "C4"); } }
        public string C5 { get { return _c5; } set { Set(ref _c5, value, "C5"); } }
        public string Status { get { return _status; } set { Set(ref _status, value, "Status"); } }
    }
}
