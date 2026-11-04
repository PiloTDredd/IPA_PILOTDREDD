# Архитектура IPA Dredd 4.3

Решения и их причины собраны в [DECISIONS.md](DECISIONS.md). Здесь описано, *как* устроена система.

## 1. Слои

```text
┌──────────────────────────────── GUI (Windows, WPF) ────────────────────────────────┐
│  MainWindow.xaml + Themes/*.xaml          Pages/*.ps1 (обработчики экранов)         │
│  Localization (x:Uid → ru/en.json)        TaskRunner.ps1 (runspace-пул, очередь)    │
└───────────────▲───────────────────────────────────────┬────────────────────────────┘
                │ сообщения log/progress/status          │ Start-DreddTask { Core-функция }
                │ (ConcurrentQueue, DispatcherTimer)      ▼
┌────────────────────────────── Core: модуль IPADredd.Core ──────────────────────────┐
│ Context · Settings · Logging(маскирование) · Process(запуск, отмена, таймауты)      │
│ Binaries · Ipatool · Accounts · AppLists · History · Library(plist) · Downloads      │
│ Devices · Diagnostics · RemoteLists · Localization                                   │
└───────┬───────────────────┬─────────────────────┬────────────────────┬──────────────┘
        │                   │                     │                    │
        ▼                   ▼                     ▼                    ▼
  ipatool-cpp          ideviceinstaller      Files/ (списки,     ~/.ipatool/ (сессии,
  (App Store)          idevice_id            настройки,           маркер login,
                       ideviceinfo (USB)     истории), Apps/,     <email>/ аккаунты)
                                             Logs/
```

Правила:
- **Core не знает про UI.** Нет `Read-Host`, `Write-Host`, WPF. Вместо вывода на экран вызывается `$Reporter` (скриптблок или $null), отмена приходит через `CancellationToken`.
- **GUI не вызывает внешние программы напрямую.** Только функции Core, длительные — через `TaskRunner`.
- **Все пути строятся из контекста** (`New-DreddContext`): корень приложения, `Files`, папка загрузок, `Logs`, `~/.ipatool`, найденные бинарники.

## 2. Структура папки

```text
IPA_Dredd_4.3.0/
├── IPA_Dredd.ps1                  точка входа GUI (-SelfTest, -Screenshot <папка>)
├── Start_IPA_Dredd_Windows.bat    запуск двойным кликом
├── README.md                      кратко для пользователя
├── src/
│   ├── Core/
│   │   ├── IPADredd.Core.psm1     загружает части и экспортирует функции
│   │   ├── Native/PlistReader.cs  XML + bplist00 → словари
│   │   └── *.ps1                  Context, Settings, Logging, Process, Binaries, Ipatool,
│   │                              Accounts, AppLists, History, Library, Downloads,
│   │                              Devices, Diagnostics, RemoteLists, Localization
│   ├── Localization/ru.json, en.json
│   └── GUI/
│       ├── MainWindow.xaml, VersionsDialog.xaml, Dialog.xaml
│       ├── Native/ViewModels.cs   строки таблиц с INotifyPropertyChanged
│       ├── Themes/Styles.xaml, Dark.xaml, Light.xaml
│       ├── TaskRunner.ps1, Gui.ps1
│       └── Pages/Dashboard.ps1, Catalog.ps1, Downloads.ps1, Library.ps1,
│                 Devices.ps1, Accounts.ps1, Settings.ps1, Diagnostics.ps1
├── Files/                         AppsList.txt, AppsListCustom.txt, Settings.txt,
│                                  PurchasedAppsList.json, DownloadHistory.json
├── Apps/                          папка загрузок по умолчанию
├── Logs/                          журналы по дням (email замаскирован)
├── tests/                         Run-Tests.ps1, *.Tests.ps1, fixtures/ (фейковый ipatool)
└── tools/Build-Release.ps1        сборка zip с MainApp
```

`MainApp` в рабочем дереве не дублируется, порядок поиска описан в ADR-004.

## 3. Ключевые потоки

### 3.1 Запуск
1. `IPA_Dredd.ps1`: STA-поток, загрузка WPF, `Import-Module IPADredd.Core`.
2. `New-DreddContext`: чтение `Settings.txt`, создание папок, поиск бинарников.
3. Сборка окна, применение темы и языка, показ Dashboard.
4. Фоном: `auth info` (текущий аккаунт), скан устройств (если есть `idevice_id`), индексация библиотеки, обновление списков (если включено).

### 3.2 Загрузка
```text
UI: выбор приложения(й) → [версия?] → очередь загрузок
TaskRunner → Invoke-DreddDownload(ctx, appId, versionId?, purchase?, reporter, token)
  1. temp = %TEMP%/IPADredd/<guid>/
  2. ipatool download -i ID [-–external-version-id V] [--purchase] -o temp/app.ipa
     · stdout/stderr → журнал (маскирование), % из вывода → progress
     · параллельно: размер файлов в temp → progress (байты)
     · token.Cancel → kill процесса → удаление temp
  3. Get-IpaMetadata (zip + plist) → валидация
  4. имя по шаблону ADR-007, уникализация → перенос в папку загрузок
  5. DownloadHistory.json += {appId, name, version, account, file, date}
  6. (если --purchase и успех) PurchasedAppsList.json — без изменений формата 4.2
```

### 3.3 Вход в Apple ID
```text
Форма: email + пароль (+ код 2FA)
→ ipatool auth login -e … -p … [-a …] [--keychain-passphrase …]   (в журнале: -p ***)
→ код 0 → kbsync --refresh → создать ~/.ipatool/login → auth info → обновить UI
→ ответ похож на 2FA → показать поле кода → повтор с -a
Консольный вход: Start-Process <ipatool> auth login (интерактивно), после закрытия → auth info → маркер
```

### 3.4 Аккаунты (совместимо с 4.2)
- Добавить: активные `account/cookies/login` → `~/.ipatool/<текущий email>/`, затем вход нового.
- Переключить: активные → в папку текущего, файлы выбранного → в `~/.ipatool/`, проверка `auth info`.
- Выйти из текущего: `auth revoke`, удалить активные файлы.
- Забыть сохранённый: удалить папку `~/.ipatool/<email>/` (с подтверждением).

### 3.5 Установка
`idevice_id -l` → для каждого UDID: имя (`idevice_id <UDID>`), `ideviceinfo -k ProductVersion/ProductType/DeviceClass` → таблица.
Установка: для каждой пары (IPA, устройство) сравниваются MinimumOSVersion и версия iOS. Если устройство старее, показывается предупреждение и пара пропускается, пока пользователь не подтвердит. Затем `ideviceinstaller -u UDID install <копия в temp>`, при ошибке `upgrade`. Копия в temp нужна из-за проблем ideviceinstaller на Windows с не-ASCII путями (поведение 4.2).

## 4. Модель потоков (ADR-003)

```text
UI-поток (STA)                         Runspace-пул (1..4)
──────────────                         ───────────────────
Start-DreddTask ── BeginInvoke ──────► Import-Module Core; & $Script $Ctx $Args $Reporter $Token
DispatcherTimer 100 мс ◄── Queue ───── $Reporter.Invoke('log'|'progress'|'status', …)
  · дописать журнал, прогресс, статус
  · IsCompleted → EndInvoke → OnSuccess/OnError (в UI-потоке)
Кнопка «Отмена» → CTS.Cancel() ──────► Invoke-DreddProcess видит токен → Kill
```

## 5. Форматы данных

| Файл | Формат | Совместимость |
|---|---|---|
| `Settings.txt` | `Key=Value` в UTF-8 | ключи 4.2 (`Language`, `DebugEnabled`, `KeychainEnabled`) плюс новые (`Theme`, `DownloadFolder`, `BinaryRoot`, `UpdateListsOnStartup`, `AutoPurchase`, `FileNameIncludeAccount`, `RemoteListBaseUrl`) |
| `AppsList.txt`, `AppsListCustom.txt` | `Имя: ID`, по строке | как в 4.1/4.2 |
| `PurchasedAppsList.json` | `{ "<email>": [ {"Name","AppID"} ] }`, всегда массив | читается 4.2 |
| `DownloadHistory.json` | `[ {"Date","AppID","Name","Version","Account","File","Result"} ]`, последние 500 | новый |
| `Logs/yyyy-MM-dd.log` | `HH:mm:ss [LEVEL] [область] текст` | новый |

## 6. Обработка ошибок
- Core-функции возвращают объект результата `{ Success, Data, Error, ExitCode, Output }` или бросают исключения с понятным текстом. GUI показывает текст и пишет подробности в журнал.
- `Resolve-DreddToolError` переводит типичные ответы ipatool в подсказки: не выполнен вход, нужна 2FA, нет лицензии, нет в регионе, сетевая ошибка. Тексты ipatool **не проверены** на всех сценариях, неизвестный ответ показывается как есть.
- Отсутствие бинарника не роняет приложение: соответствующие действия выключаются, а Dashboard и «Диагностика» показывают, что нужно сделать.
