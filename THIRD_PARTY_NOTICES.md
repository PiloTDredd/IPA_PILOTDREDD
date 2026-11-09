# Сторонние компоненты

IPA PILOTDREDD распространяется под лицензией MIT (см. [LICENSE](LICENSE)). Ниже — то, на чём программа основана и что она использует.

| Компонент | Лицензия | Как используется |
|---|---|---|
| [IPA Downloader](https://github.com/kda2495/IPA_Downloader) (kda2495) | MIT | Основа проекта; набор компонентов для первой установки; список популярных приложений `Files/AppsList.txt`. Уведомление об авторстве — в [LICENSE](LICENSE). |
| [ipatool-cpp](https://github.com/Sorvigolova/ipatool) (порт [majd/ipatool](https://github.com/majd/ipatool), © 2021 Majd Alfhaily) | MIT | **Не входит в репозиторий и релизы.** Скачивается программой: при первой установке — из официального релиза IPA Downloader, обновления — из официальных релизов ipatool-cpp (проверка SHA-256). В исполняемый файл ipatool-cpp при сборке вшиваются библиотеки Apple, на которые лицензия MIT не распространяется. |
| [libimobiledevice](https://github.com/libimobiledevice/libimobiledevice), libplist, libusbmuxd | LGPL-2.1 | **Не входят в репозиторий и релизы.** Скачиваются при первой установке из официального релиза IPA Downloader. |
| [ideviceinstaller](https://github.com/libimobiledevice/ideviceinstaller) | GPL-2.0 | **Не входит в репозиторий и релизы.** Скачивается при первой установке вместе с ними; запускается как отдельная программа. |
| iTunes Search/Lookup API (Apple) | — | Публичный API без авторизации: названия, версии и иконки купленных приложений. Иконки и названия принадлежат их правообладателям и кэшируются только локально. |

IPA PILOTDREDD не обходит защиту Apple и работает только с покупками вашего собственного Apple ID.
