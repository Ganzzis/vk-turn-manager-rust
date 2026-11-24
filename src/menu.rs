use crate::{client, connections, logs, network, reinstall, setup, status, uninstall, Result};
use std::ffi::OsString;
use std::io::{self, Write};
use std::path::Path;

fn ask(prompt: &str) -> Result<Option<String>> {
    print!("{prompt} ");
    io::stdout().flush()?;
    let mut input = String::new();
    if io::stdin().read_line(&mut input)? == 0 {
        return Ok(None);
    }
    Ok(Some(input.trim().to_owned()))
}

fn client_action(args: &[&str]) -> Result<()> {
    let result = client::execute(&args.iter().map(OsString::from).collect::<Vec<_>>())?;
    if let Some(peers) = result.as_array() {
        if peers.is_empty() {
            println!("Управляемых клиентов пока нет.");
        }
        for peer in peers {
            println!(
                "{} — {}",
                peer["name"].as_str().unwrap_or_default(),
                peer["ipv4"].as_str().unwrap_or_default()
            );
        }
    } else if let (Some(name), Some(address)) = (result["name"].as_str(), result["ipv4"].as_str()) {
        println!("Клиент {name} ({address}).");
    }
    Ok(())
}

fn export() -> Result<()> {
    let Some(name) = ask("Имя клиента (пусто — отмена):")?.filter(|s| !s.is_empty())
    else {
        return Ok(());
    };
    let Some(endpoint) = ask("Публичный адрес SRTP, например vpn.example.org:56004:")?
    else {
        return Ok(());
    };
    let Some(vk) = ask("Путь к файлу 0600 со ссылкой на звонок VK:")?
    else {
        return Ok(());
    };
    let Some(link) = ask("Путь для новой ссылки, например phone.url:")?
    else {
        return Ok(());
    };
    client_action(&[
        "export",
        &name,
        "--srtp-endpoint",
        &endpoint,
        "--vk-link-file",
        &vk,
        "--output",
        &link,
    ])?;
    println!("Ссылка сохранена в {link} (0600).");
    if let Some(image) =
        ask("Путь для PNG с QR-кодом (пусто — пропустить):")?.filter(|s| !s.is_empty())
    {
        client::qr(Path::new(&link), Path::new(&image))?;
        println!("QR-код сохранён в {image} (0600).");
    }
    Ok(())
}

pub(super) fn run() -> Result<()> {
    loop {
        println!(
            "\nVK TURN Manager\n\
             1. Установить сервер и включить IPv4 NAT\n\
             2. Добавить клиента\n\
             3. Список клиентов\n\
             4. Удалить клиента\n\
             5. Создать ссылку и QR-код для VK TURN Proxy\n\
             6. Статус служб\n\
             7. Подключения WireGuard\n\
             8. Последние записи журнала\n\
             9. Переустановить SRTP с сохранением конфигурации\n\
             10. Проверить и включить IPv4 NAT\n\
             11. Удалить сервер\n\
             0. Выход"
        );
        let Some(choice) = ask("Выберите действие:")? else {
            return Ok(());
        };
        let result = match choice.as_str() {
            "0" => return Ok(()),
            "1" => setup(),
            "2" | "4" => {
                let Some(name) = ask("Имя клиента (латиница, цифры, дефис; пусто — отмена):")?
                    .filter(|s| !s.is_empty())
                else {
                    continue;
                };
                if choice == "4" && ask("Удалить клиента? Введите ДА:")?.as_deref() != Some("ДА")
                {
                    continue;
                }
                client_action(&[if choice == "2" { "add" } else { "remove" }, &name])
            }
            "3" => client_action(&["list"]),
            "5" => export(),
            "6" => status(),
            "7" => connections(),
            "8" => logs(),
            "9" => reinstall(),
            "10" => network::plan().and_then(|()| {
                if ask("Включить NAT и глобальный IPv4 forwarding? Введите ДА:")?.as_deref()
                    == Some("ДА")
                {
                    network::enable()
                } else {
                    Ok(())
                }
            }),
            "11" => {
                if ask("Удалить службы и рабочую конфигурацию? Введите УДАЛИТЬ:")?.as_deref()
                    == Some("УДАЛИТЬ")
                {
                    uninstall()
                } else {
                    Ok(())
                }
            }
            _ => {
                println!("Выберите номер из меню.");
                continue;
            }
        };
        if let Err(error) = result {
            eprintln!("Ошибка: {error}");
        }
    }
}
