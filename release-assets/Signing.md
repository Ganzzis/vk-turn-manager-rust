# Подпись и установка VK TURN Proxy Manager 1.0.0

`VKServerManager-unsigned.ipa` собран для arm64 iPhone и требует подписи. Минимальная система — iOS 17. Сборка 2. Для установки потребуется Mac с сертификатом Apple Development и профилем, разрешающим установку на ваш iPhone.

1. Скачайте IPA и `SHA256SUMS`. Сверьте результат `shasum -a 256 VKServerManager-unsigned.ipa` со строкой для IPA в манифесте. Если скачаны все вложения релиза, проверьте их одной командой `shasum -a 256 -c SHA256SUMS`.
2. Подпишите IPA тем же способом, которым подписывали тестовую сборку. Для обновления поверх неё используйте ту же Apple Team и тот же Bundle Identifier, что в установленном приложении. Это сохраняет доступ приложения к существующим записям Keychain. Используйте профиль для этого идентификатора и зарегистрированного iPhone. Пакету не нужны Network Extension, VPN-entitlements, App Groups или Keychain Sharing.
3. Для подписи через Xcode используйте исходники тега `ios-v1.0.0` и Xcode 26 с XcodeGen. Извлеките каталог `Payload/VKServerManager.app/ServerBundle` из IPA и скопируйте его целиком в `ios-manager/ServerBundle`. В каталоге `ios-manager` выполните `xcodegen generate`, откройте `VKServerManager.xcodeproj` и в Signing & Capabilities выберите Team и Bundle Identifier. Подключите iPhone, включите режим разработчика для установки development-сборки и нажмите Run. Для экспорта подпишите архив через Product → Archive → Distribute App и выберите подходящий development/ad hoc профиль.
4. После установки откройте приложение, выберите VPS и обновите статус. При новом подключении сверьте SSH-отпечаток с отпечатком из доверенной консоли провайдера. Для подключения к VPN импортируйте профиль клиента в оригинальном VK TURN Proxy.

Сохраните `Licenses.zip` и `srtp-build478-source.tar.gz` при передаче архива другому пользователю.
