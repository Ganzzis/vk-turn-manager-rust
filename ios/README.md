# VK TURN Manager for iOS

Нативное приложение SwiftUI и расширение Packet Tunnel для iOS 17 и новее. В приложении можно добавлять, менять и удалять профили, импортировать ссылки `vkturnproxy://import?data=…`, запускать прямой WireGuard и смотреть статус и счётчики пакетов. Интерфейс показывает подключение после аутентифицированного рукопожатия и применения маршрутов системным NetworkExtension.

## Транспорт

- **Прямой WireGuard** передаёт зашифрованные UDP-датаграммы через Network.framework. Rust Core обрабатывает рукопожатие, шифрование, таймеры, подтверждения и маршруты IPv4. Packet Tunnel читает и записывает IP-пакеты через публичный API `NEPacketTunnelFlow`. Для профиля используйте прямой WireGuard endpoint и разрешите доступ к его UDP-порту.
- **TURN + DTLS-SRTP** использует временные TURN credentials, UDP или TCP для управляющего соединения, UDP relay, DTLS 1.2 с Extended Master Secret и SRTP AES-128-CM/HMAC-SHA1-80. Совместимость с `srtp-build478` проверена через локальный TURN и реальное WireGuard-рукопожатие.
- **Автоматический bootstrap VK/OK** пока недоступен. У upstream поток опирается на параметры приложения, недокументированные VK/OK-методы, авторизацию или CAPTCHA. Публичный поддерживаемый контракт, позволяющий повторить его без переноса чужих идентификаторов приложения и обхода проверок, не установлен. Режимы WRAP, CSQTT и IPv6-туннелирование также не входят в эту сборку.

### Подключение через TURN

1. Импортируйте профиль `vkturnproxy://` и откройте его для редактирования. Оставьте адрес SRTP-сервера в основном поле Endpoint.
2. Включите временные credentials, введите адрес **TURN-ретранслятора**, имя, пароль и срок Unix UTC, полученные через разрешённую систему выдачи. Требуется от 30 секунд до 24 часов до истечения на момент запуска. Выберите TCP или UDP согласно выданному адресу. Встроенного входа VK и экрана решения CAPTCHA пока нет.
3. Для проверки сертификата DTLS задайте SHA-256 DER-сертификата, полученный по доверенному каналу. Штатный build478 генерирует самоподписанный сертификат при запуске. При отсутствии pin внешняя DTLS-сессия не аутентифицирует сервер; конечный пир по-прежнему аутентифицируется неизменным публичным ключом WireGuard. WireGuard-рукопожатие обязательно даже после успешных TURN и DTLS.
4. Приложение ограничивает очереди и ставит IPv4 MTU 1280. При потере ранее работавшего реле оно один раз пересоздаёт транспорт и WireGuard-сессию, показывая переподключение до новой аутентификации. При истечении credentials требуется обновить их вручную. TURN поверх TLS и IPv6-адреса реле или SRTP-сервера пока не поддерживаются.

Приватные ключи, PresharedKey, endpoint и ссылки находятся в device-only Keychain. В настройках приложения хранятся UUID, название и тип профиля. В конфигурации NetworkExtension сохраняется UUID, а расширение получает сам профиль через общую Keychain access group. Диагностика показывает состояние и счётчики, без конфигураций, ключей и адресов.

## Сборка

На macOS с Xcode, Rust 1.100 и XcodeGen:

```sh
bash ios/scripts/build-core.sh
cd ios
xcodegen generate
open VKMobile.xcodeproj
```

Rust Core также собирается и тестируется самостоятельно на Linux или macOS:

```sh
cargo fmt --manifest-path ios/Core/Cargo.toml --all -- --check
cargo test --manifest-path ios/Core/Cargo.toml --locked
```

В GitHub Actions workflow **iOS CI** тестирует Rust, собирает статические библиотеки для `aarch64-apple-ios` и архитектуры симулятора, запускает XCTest и создаёт неподписанный архив устройства. В архивном артефакте прилагаются тексты лицензий зависимостей. Неподписанный архив предназначен для проверки сборки.

## Подпись и iPhone

Для использования оригинального VK TURN Proxy iOS подписывать это приложение не требуется. [Серверная совместимость и проверка оригинального клиента](../docs/ios-compatibility.md).

### Идентификаторы и разрешения

1. В Apple Developer зарегистрируйте два явных App ID. Задайте собственный `VK_BUNDLE_ID` для **VKMobile**. Идентификатор **PacketTunnel** будет `VK_BUNDLE_ID.packet-tunnel`. Используйте одну команду подписи для обоих target.
2. Включите **Network Extensions → Packet Tunnel** и **Keychain Sharing** у обоих target. Для приложения и расширения значение `com.apple.developer.networking.networkextension` должно включать `packet-tunnel-provider` в подписанном коде и provisioning profiles. В архивированном приложении проверьте наличие `PlugIns/PacketTunnel.appex` и extension point `com.apple.networkextension.packet-tunnel`.
3. Выберите одну общую Keychain access group для обоих target. Значение `VK_KEYCHAIN_GROUP` в проекте должно раскрываться в одно и то же конкретное имя в `VKKeychainGroup` обоих Info.plist и в подписанных `keychain-access-groups`. Профили должны разрешать эту группу. По умолчанию проект использует `TEAM_ID.bundle-id.shared`. Если App Identifier Prefix отличается от Team ID, переопределите `VK_KEYCHAIN_GROUP` с правильным префиксом.
4. **App Groups** нужны при добавлении общего файлового контейнера или `UserDefaults(suiteName:)` между процессами. Текущая сборка использует общий Keychain и собственные настройки приложения. Если вашей сборке требуется общий контейнер, зарегистрируйте `group.<ваш-id>`, назначьте группу обоим App ID и добавьте один и тот же `com.apple.security.application-groups` в оба файла entitlements. Обновите оба provisioning profile и передайте ожидаемую группу через `--app-group` при проверке.
5. Зарегистрируйте UDID iPhone, обновите профили после изменения capabilities и создайте подписанный архив в Xcode. Экспортируйте development или ad hoc IPA для зарегистрированного устройства. Сертификаты, приватные ключи, профили подписи, IPA и UDID держите в закрытом хранилище.

Подробнее в документации Apple. [Network Extensions](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.networkextension), [App Groups](https://developer.apple.com/documentation/xcode/configuring-app-groups), [Keychain Sharing](https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps), [Provisioning Profiles](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles).

### Проверка подписанного IPA и устройства

На Mac из корня репозитория выполните:

```sh
python3 ios/scripts/check-signing.py /path/to/VKMobile.ipa \
  --bundle-id org.example.vkturn --team-id YOUR_TEAM_ID --device-udid "$IPHONE_UDID"
```

Если включили App Groups, добавьте `--app-group group.org.example.vkturn` для каждой ожидаемой группы. Иначе проверка требует отсутствия App Groups в подписи. Скрипт проверяет подписи приложения и расширения, сертификат в каждом профиле, Team ID и явные App ID, срок действия профилей и наличие UDID, Packet Tunnel, App Groups и общую Keychain access group. Он удаляет временную распаковку после проверки и выводит только результат. Команда предназначена для подписанных development и ad hoc IPA с embedded profiles.

Установите **тот же IPA** на зарегистрированный физический iPhone. После разблокировки устройства создайте профиль с отдельным тестовым пиром, закройте и снова откройте приложение, убедитесь, что профиль доступен. Запустите VPN и подтвердите системный запрос. Проверьте, что Packet Tunnel прочитал профиль из общего Keychain, WireGuard установил рукопожатие, через туннель проходит IPv4-трафик в обе стороны и VPN штатно останавливается и запускается повторно. Включите проверку общего контейнера, если добавили App Groups. Зафиксируйте номер сборки, модель iPhone, версию iOS и результаты без конфигураций и ключей.

Заявлять поддержку VPN в собственной сборке можно после успешной проверки подписанного IPA и туннеля на устройстве. Текущая реализация нацелена на прямой WireGuard. Импорт SRTP-профиля проверяется отдельно и не подтверждает поддержку SRTP-туннеля в приложении.

## Upstream и лицензии

- [VK TURN Proxy iOS, коммит 0fddeef5](https://github.com/anton48/vk-turn-proxy-ios/tree/0fddeef5b70044a0cf9bcd9fe093edfc4956d8c6) и [сервер srtp-build478](https://github.com/anton48/vk-turn-proxy/tree/f954cb04ac17f49059f6fe5630a09428ff04c242) изучены для совместимости режимов и формата. Схема импорта сверена с `ConnectionLink`, `ConnectionSettings`, парсером и `quick_link.py`. GPLv3-код upstream в приложение не копировался и с ним не линкуется. При будущей интеграции Go-стека нужно сохранить уведомления GPLv3, установить условия распространения производной сборки и обеспечить соответствующий исходный код.
- [BoringTun 0.7.1, коммит 253f7afb](https://github.com/cloudflare/boringtun/tree/253f7afb2b3df9e952065d10bf2af19913cb176b) линкуется как библиотека BSD-3-Clause. Сохранён [текст лицензии](Licenses/BoringTun.BSD-3-Clause.txt). Для двоичного распространения прилагайте копирайт, условия и отказ от гарантий. Остальные Rust-зависимости закреплены в `Core/Cargo.lock`; `scripts/notices.py` собирает их тексты лицензий и сведения об исходниках для архива.


### Зависимости транспорта и воспроизводимость

TURN, DTLS, SRTP и webrtc-util закреплены на 0.17.3 в `Core/Cargo.lock` (MIT или Apache-2.0). `libc` и `mio` закреплены в lockfile на версиях, совместимых с используемым webrtc-util/Nix на iOS. Рабочий формат сверён с [srtpwrap и сервером build478](https://github.com/anton48/vk-turn-proxy/tree/f954cb04ac17f49059f6fe5630a09428ff04c242/server). GPL-код VK bootstrap не встроен. CI скачивает отдельный Linux-бинарник upstream, сверяет опубликованный SHA-256 и выполняет тесты на loopback с синтетическими credentials. Он не включается в iOS-архив. Для локального прогона укажите путь к проверенному бинарнику:

```sh
VK_SRTP_SERVER=/absolute/path/server-linux-amd64 cargo test --manifest-path ios/Core/Cargo.toml --locked wireguard_through_turn_and_build478 -- --ignored
```
