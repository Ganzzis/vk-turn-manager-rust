# VK TURN Manager

Минимальный установщик для Ubuntu 24.04. Он устанавливает `wireguard-tools`, проверяет SHA-256 релизного сервера `srtp-build478` и запускает два systemd-сервиса.

```text
Клиент DTLS-SRTP → UDP 56004 → VK TURN Proxy → 127.0.0.1:51820 → WireGuard wg-vk
```

## Установка

На Ubuntu 24.04 с systemd откройте каталог репозитория. Понадобятся `sudo`, Rust 1.89+ с Cargo и системный компоновщик (например, из `build-essential`). Подготовьте серверный `wg-vk.conf` с закрытым ключом, адресом интерфейса и секциями `[Peer]` для ваших клиентов. В `[Interface]` задайте следующие параметры:

```ini
ListenPort = 51820
Table = off
```

Выберите VPN-подсеть, свободную на сервере. `Table = off` отключает автоматическое добавление маршрутов из `AllowedIPs`. Для обычной подсети WireGuard используется маршрут, автоматически появляющийся при назначении адреса интерфейсу. Установщик отклоняет `DNS`, `SaveConfig` и хуки `PreUp`/`PostUp`/`PreDown`/`PostDown`.

Выполните одну команду:

```bash
cargo build --locked --release && sudo ./target/release/vk-turn-manager install ./wg-vk.conf
```

Готовый Linux amd64 бинарник также можно скачать из артефактов успешного запуска Rust CI в GitHub Actions. Артефакт доступен 7 дней. После распаковки выдайте бинарнику право на запуск с помощью `chmod +x vk-turn-manager` и выполните `sudo ./vk-turn-manager install ./wg-vk.conf`. Установщик выбирает релизный SRTP-сервер для amd64 или arm64.

Службы используют свободный интерфейс `wg-vk` и UDP-порты 51820 и 56004. При наличии `/etc/wireguard/wg-vk.conf` или конфликтующего юнита установка прерывается. Рабочая копия конфигурации хранится в `/etc/vk-turn-manager/wg-vk.conf` с правами `0600`. Сетевые правила и IP forwarding задаются отдельно администратором. Для внешнего SRTP-трафика разрешите UDP 56004 в файрволе и в настройках VPS. Трафик от SRTP к WireGuard идёт по loopback, поэтому для этого пути достаточно локальной доступности UDP 51820.

## Проверка и удаление

```bash
sudo ./target/release/vk-turn-manager status
sudo wg show wg-vk
sudo ss -lun '( sport = :51820 or sport = :56004 )'
sudo journalctl -u vk-turn-wireguard.service -u vk-turn-srtp.service -b
```

Ожидаются активные юниты `vk-turn-wireguard.service` и `vk-turn-srtp.service`, интерфейс `wg-vk` с UDP 51820 и слушающий сервер на UDP 56004. Подключите клиент с поддержкой транспорта DTLS-SRTP к адресу VPS на порту 56004. Проверьте, что `sudo wg show wg-vk` показывает свежее рукопожатие нужного пира и рост счётчиков в обоих направлениях, затем проверьте доступ до VPN-адреса сервера. Для маршрутизации за пределы VPN-подсети настройте и проверьте необходимые маршруты, forwarding и правила файрвола.

```bash
sudo ./target/release/vk-turn-manager uninstall
```

Удаление останавливает оба управляемых сервиса и удаляет их юниты, SRTP-бинарник и рабочую копию WireGuard-конфигурации. Исходная конфигурация и системные пакеты сохраняются.

## Версия SRTP

[Релиз srtp-build478](https://github.com/anton48/vk-turn-proxy/releases/tag/srtp-build478) соответствует коммиту `f954cb04ac17f49059f6fe5630a09428ff04c242`. [Upstream workflow](https://github.com/anton48/vk-turn-proxy/blob/srtp-build478/.github/workflows/release.yml) собирает Linux-сервер с Go 1.25.5:

```bash
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags '-s -w -checklinkname=0' -trimpath -o server-linux-amd64 ./server
./server-linux-amd64 -srtp -listen 0.0.0.0:56004 -connect 127.0.0.1:51820
```

Режим `-srtp` принимает DTLS-SRTP и передаёт извлечённые UDP-данные на `-connect`. На VPS компилятор Go для установки сервера не требуется.

Лицензия MIT.
