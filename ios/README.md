# VK TURN Manager for iOS

Нативное приложение SwiftUI и расширение Packet Tunnel для iOS 17 и новее. В приложении можно добавлять, менять и удалять профили, импортировать ссылки `vkturnproxy://import?data=…`, запускать прямой WireGuard и смотреть статус и счётчики пакетов. Интерфейс показывает подключение после аутентифицированного рукопожатия и применения маршрутов системным NetworkExtension.

## Транспорт

- **Прямой WireGuard** передаёт зашифрованные UDP-датаграммы через Network.framework. Rust Core обрабатывает рукопожатие, шифрование, таймеры, подтверждения и маршруты IPv4. Packet Tunnel читает и записывает IP-пакеты через публичный API `NEPacketTunnelFlow`. Для профиля используйте прямой WireGuard endpoint и разрешите доступ к его UDP-порту.
- **VK TURN SRTP** импортируется и хранится с соответствующим типом и SRTP endpoint. Запуск этого профиля отклоняется с явным объяснением. Прямой WireGuard не используется как замена. Для подключения SRTP требуется клиентская реализация VK/TURN bootstrap и DTLS-SRTP, включая получение временных TURN credentials и обработку сценариев VK авторизации и CAPTCHA. У upstream эти части находятся в связанном GPLv3 Go-стеке. Интеграция этого стека требует отдельной проверки лицензирования и совместимости с сервером. Режимы WRAP, CSQTT и IPv6-туннелирование этим клиентом не поддерживаются.

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

1. В аккаунте Apple Developer заведите идентификаторы приложения и расширения. По умолчанию используются `org.ganzzis.vkturn` и `org.ganzzis.vkturn.packet-tunnel`. При необходимости задайте свой `VK_BUNDLE_ID`.
2. Для обоих target включите **Network Extensions → Packet Tunnel** и **Keychain Sharing**. Выберите одну команду подписи, зарегистрируйте устройство и обновите provisioning profiles. Значение `VK_KEYCHAIN_GROUP` должно совпадать в обоих target, их Info.plist и профилях подписи. По умолчанию оно определяется как `TEAM_ID.bundle-id.shared`. При отличающемся App Identifier Prefix переопределите это значение.
3. Соберите и установите приложение с подписью из Xcode. На физическом iPhone добавьте синтетический пир, разрешите установку VPN-конфигурации, проверьте WireGuard-рукопожатие на тестовом сервере и IP-трафик, затем отключите туннель. Симуляторные тесты выполняют FFI и CRUD на тестовом хранилище. Реальные entitlement, общий Keychain и жизненный цикл системного туннеля проверяются на устройстве.

## Upstream и лицензии

- [VK TURN Proxy iOS, коммит 0fddeef5](https://github.com/anton48/vk-turn-proxy-ios/tree/0fddeef5b70044a0cf9bcd9fe093edfc4956d8c6) и [сервер srtp-build478](https://github.com/anton48/vk-turn-proxy/tree/f954cb04ac17f49059f6fe5630a09428ff04c242) изучены для совместимости режимов и формата. Схема импорта сверена с `ConnectionLink`, `ConnectionSettings`, парсером и `quick_link.py`. GPLv3-код upstream в приложение не копировался и с ним не линкуется. При будущей интеграции Go-стека нужно сохранить уведомления GPLv3, установить условия распространения производной сборки и обеспечить соответствующий исходный код.
- [BoringTun 0.7.1, коммит 253f7afb](https://github.com/cloudflare/boringtun/tree/253f7afb2b3df9e952065d10bf2af19913cb176b) линкуется как библиотека BSD-3-Clause. Сохранён [текст лицензии](Licenses/BoringTun.BSD-3-Clause.txt). Для двоичного распространения прилагайте копирайт, условия и отказ от гарантий. Остальные Rust-зависимости закреплены в `Core/Cargo.lock`; `scripts/notices.py` собирает их тексты лицензий и сведения об исходниках для архива.
