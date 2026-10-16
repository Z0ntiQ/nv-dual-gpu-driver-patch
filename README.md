# nv-dual-gpu-driver-patch

Патч INF датацентрового драйвера NVIDIA для одновременной работы GeForce-карты и Tesla/Quadro-карты на одном Windows-хосте под одним `nvlddmkm.sys`.

## Как этим пользоваться (кратко)

Инструмент состоит из двух файлов: `patch-nv-dual-gpu.cmd` (запуск по двойному клику, сам поднимает администратора) и `patch-nv-dual-gpu.ps1` (вся логика, фазы `Prep` / `Install` / `Verify` / `Revert` / `DryRun`). Всю работу делает одна фаза `Prep`: патчит INF, подписывает пакет, включает тестовый режим, перезагружает машину — а после перезагрузки сама же и устанавливает драйвер через одноразовую системную задачу. От пользователя требуются четыре действия:

```powershell
# 0. PowerShell от администратора, в папке с файлами.
#    Заменить HWID/донора на свои (см. шаги 2-3 ниже).

# 1. Проверка без побочных эффектов: пакет найден, строки INF сгенерированы верно
.\patch-nv-dual-gpu.ps1 -Phase DryRun -TargetHwid "PCI\VEN_10DE&DEV_1F03&SUBSYS_886D1043" -DonorHwid DEV_1EB8

# 2. Применить: патч + подпись + тестовый режим + перезагрузка + автосустановка после неё
.\patch-nv-dual-gpu.ps1 -Phase Prep -TargetHwid "PCI\VEN_10DE&DEV_1F03&SUBSYS_886D1043" -DonorHwid DEV_1EB8

# 3. После перезагрузки проверить обе карты (Code 0, одна версия драйвера)
.\patch-nv-dual-gpu.ps1 -Phase Verify

# 4. Выключить тестовый режим (Prep его сам не выключает)
bcdedit /set testsigning off; shutdown /r /t 5
```

Откат в исходное состояние: `-Phase Revert`. Полный порядок действий с определением своих ID — в разделе «Применение на своей машине» ниже.

## Проверенная конфигурация

| Компонент | Значение |
|---|---|
| ОС | Windows 10 Pro, build 19041, x64 |
| Драйвер | NVIDIA **Data Center Driver for Windows 582.78**, WHQL |
| Версия пакета в Windows | `32.0.15.8278` |
| Пакет драйвера | `nv_dispwi.inf` |
| Ветка | 580 |
| CUDA Toolkit | 13.0 |
| Дата релиза драйвера | 03.08.2026 |
| Размер установщика | 725.13 MB |
| Поддерживаемые ОС драйвера | Windows 10 64-bit, Windows 11 |
| GPU 1 | Tesla V100-PCIE-32GB (`DEV_1DB6`) |
| GPU 2 | GeForce RTX 2060 (`DEV_1F03`, `SUBSYS_886D1043`) |

Официальная страница драйвера 582.78: **https://www.nvidia.com/en-us/drivers/details/274952/**

## Проблема

Windows загружает один `nvlddmkm.sys` на систему. Tesla V100 обслуживается только датацентровой веткой, GeForce RTX 2060 — только Game Ready. Пакет Game Ready (`32.0.15.6094`, ветка 560) конфликтует по версии ядра с загруженным датацентровым (`32.0.15.8278`) → RTX 2060 в Code 31.

## Метод

Ядро драйвера не модифицируется. В копию INF живого датацентрового пакета добавляется hardware ID GeForce-карты с привязкой к секции датацентр-карты того же чип-семейства. RTX 2060 (TU106) и Tesla T4 (`DEV_1EB8`) — оба Turing; ядро 582.78 поддерживает чип, INF фильтрует ID.

1. Копия пакета из `C:\Windows\System32\DriverStore\FileRepository` (пакет, содержащий `DEV_1DB6`).
2. В секции `[NVIDIA_Devices.NTamd64...]` после строки донора:
   ```
   %NVIDIA_DEV.1F03.886D.1043% = Section046, PCI\VEN_10DE&DEV_1F03&SUBSYS_886D1043
   ```
   В `[Strings]`:
   ```
   NVIDIA_DEV.1F03.886D.1043 = "NVIDIA GeForce RTX 2060"
   ```
   Формат токена: `NVIDIA_DEV.<dev>.<subsys-device>.<subsys-vendor>`. `SUBSYS_886D1043` → `886D` + `1043`.
3. Пересборка каталога под именем из INF (`CatalogFile = NV_DISP.CAT`) через WDK `makecat.exe` + CDF.
4. Подпись каталога двухуровневой цепочкой: CA root (`BasicConstraints=CA=true`, в `Root` + `TrustedPublisher` + `CA`) → leaf (`CA=false`, EKU KMCS `1.3.6.1.4.1.311.10.3.5` + Code Signing, в `TrustedPublisher`); подписывает leaf.
5. `bcdedit /set testsigning on`, перезагрузка, `pnputil /add-driver <inf> /install`.
6. `bcdedit /set testsigning off` + перезагрузка. `nvlddmkm.sys` остаётся оригинальным WHQL-файлом NVIDIA; подпись каталога проверяется при установке, поэтому тестовый режим после установки не требуется.

Не проходят: self-signed без CA в `Root` (`0x800b0109` → `0xE0000242`), подпись каталога CA-сертификатом напрямую (`0x80096019`), `signtool` без `/sc LocalMachine` (ключ в машинном `My`).

## Зачем нужен тестовый режим и почему его можно выключить

Windows при загрузке ядра принимает только те драйверы, чья подпись восходит к встроенным корням Microsoft (WHQL-подпись NVIDIA). Правка INF меняет файл пакета, поэтому хеши в `.cat` перестают совпадать и оригинальная подпись NVIDIA становится недействительной. Подписать каталог заново можно только локальным сертификатом, а цепочка из него в корни Microsoft не восходит — обычная загрузка такого пакета невозможна.

`bcdedit /set testsigning on` переключает политику проверки подписи ядра: Windows начинает принимать драйверы, подписанные сертификатом, который доверяет **локальная** система (наш leaf-сертификат в `TrustedPublisher`). Без этого шага `pnputil /add-driver` отклоняет пакет с `0xE0000202` («подпись Authenticode недействительна») независимо от корректности INF.

Тестовый режим нужен **только на время установки**. Причина, по которой он не нужен после установки: модифицируются `nv_dispwi.inf` и `NV_DISP.CAT`, а `nvlddmkm.sys` остаётся оригинальным WHQL-файлом NVIDIA. Подпись каталога проверяется подсистемой PnP при установке пакета; при загрузке ядра проверяется подпись самого `nvlddmkm.sys`, которая не менялась. Поэтому после успешной `pnputil /install` выполняется `bcdedit /set testsigning off` + перезагрузка: обе карты остаются Code 0, водяной знак «Test Mode» и пониженная политика проверки подписей исчезают. Проверено на конфигурации из таблицы выше.

Условия, без которых не работает даже тестовый режим: HVCI / Memory Integrity выключен (`KernelModeCodeIntegrityPolicyEnforcementStatus = 0`), иначе политика целостности кода ядра блокирует загрузку в принципе.

## Требования

- Установленный и работающий датацентровый драйвер 582.78 — [страница загрузки](https://www.nvidia.com/en-us/drivers/details/274952/). Tesla/Quadro-карта видна в `nvidia-smi`.
- WDK 10 (`makecat.exe` в `C:\Program Files (x86)\Windows Kits\10\bin\10.0.<ver>\x64\`).
- HVCI / Memory Integrity выключен: `Win32_DeviceGuard.KernelModeCodeIntegrityPolicyEnforcementStatus = 0`. При значении `2` test-signed драйвер не загрузится. Проверка: **Безопасность Windows → Безопасность процессора → Изоляция ядра**.
- Права администратора.
- Точка восстановления перед запуском.

## Применение на своей машине

### Шаг 1. Установить датацентровый драйвер

Скачать 582.78 со [страницы NVIDIA](https://www.nvidia.com/en-us/drivers/details/274952/) и установить. Проверить, что Tesla/Quadro-карта видна:

```powershell
nvidia-smi --query-gpu=index,name,driver_version --format=csv
```

GeForce-карта на этом этапе ожидается в Code 31 или Code 43 — это исходное состояние, которое патч устраняет.

### Шаг 2. Узнать hardware ID своей GeForce-карты

**Диспетчер устройств → карта → Свойства → Сведения → Идентификаторы оборудования**, либо:

```powershell
Get-PnpDevice -Class Display | Get-PnpDeviceProperty -KeyName DEVPKEY_Device_HardwareIds |
  Select Instance,Data | Format-List
```

Нужны значения `DEV_xxxx` и `SUBSYS_xxxxxxxx`. Пример:

```
PCI\VEN_10DE&DEV_1F03&SUBSYS_886D1043&REV_A1
```

### Шаг 3. Подобрать донора

`DEV_xxxx` своей GeForce-карты должен относиться к чип-семейству, которое ядро датацентрового драйвера уже обслуживает. Донор — датацентр/рабочая станция на том же кремнии; его секция используется для привязки.

| GeForce | Чип | Донор в INF 582.78 | Секция | Статус |
|---|---|---|---|---|
| RTX 2060 / 2070 / 2080 / Ti | TU106 / TU104 / TU108 | Tesla T4 `1EB8` | `Section046` | проверено |
| GTX 1650 / 1660 | TU117 / TU116 | T600 `1FB1`, T400 `1FB2` | `Section052` | не проверялось |
| RTX 3060 Ti – 3090 | GA102 / GA104 / GA106 | A10 `2236`, A2 `25B6`, RTX A4000 `24B0` | `Section056` / `Section065` | не проверялось |
| RTX 3050, RTX 3060 12GB | GA107 | аналога в INF нет | — | поддержка чипа не подтверждена |
| RTX 4060 – 4090 | AD102/103/104/106/107 | RTX 6000 Ada `26B1`, L4 `27B8`, RTX 4000 Ada `27B2` | `Section074` / `076` / `073` | не проверялось |
| RTX 5070 – 5090 | GB202/203/205/206 | RTX PRO 6000 `2BB1`, RTX PRO 4000 `2C34` | `Section090` / `094` | не проверялось |
| GTX 1050 – 1080 Ti | GP102/104/106/107 | P40 `1B38`, P4 `1BB3` | `Section026` | не проверялось |
| GTX 750 – 980 | GM107/117/200/204 | Tesla M60 `13F2`, M40 `17FD` | `Section010` | не проверялось |

Quadro, Tesla и RTX PRO в патче не нуждаются — их ID есть в INF.

Проверка поддержки чипа по живому INF своей машины:

```powershell
$inf = (Get-ChildItem C:\Windows\System32\DriverStore\FileRepository\nv_disp*.inf_amd64_*\nv_disp*.inf |
  Select-Object -First 1).FullName
Select-String -Path $inf -Pattern 'NVIDIA_DEV\.[0-9A-F]{4}' |
  Select-Object -ExpandProperty Line | Sort-Object -Unique
```

### Шаг 4. Прогнать DryRun

Проверяет поиск пакета и генерацию строк INF без побочных эффектов:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\patch-nv-dual-gpu.ps1 -Phase DryRun `
  -TargetHwid "PCI\VEN_10DE&DEV_1F03&SUBSYS_886D1043" -TargetName "NVIDIA GeForce RTX 2060" `
  -DonorHwid DEV_1EB8 -AnchorHwid DEV_1DB6
```

Ожидаемый вывод: найден пакет `nv_dispwi.inf_amd64_*`, целевая строка добавлена в секцию донора, токен совпадает с форматом из шага 2.

### Шаг 5. Применить

Правка параметров в начале `patch-nv-dual-gpu.cmd` под свою пару карт, затем двойной клик. Либо запуск напрямую:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\patch-nv-dual-gpu.ps1 -Phase Prep `
  -TargetHwid "PCI\VEN_10DE&DEV_1F03&SUBSYS_886D1043" -TargetName "NVIDIA GeForce RTX 2060" `
  -DonorHwid DEV_1EB8 -AnchorHwid DEV_1DB6 -WorkDir "E:\AI\nv_dualgpu"
```

Фаза `Prep` выполняет: самоповышение → поиск пакета по `-AnchorHwid` → копию в `-WorkDir` → патч INF → создание цепочки сертификатов → пересборку и подпись каталога → `bcdedit /set testsigning on` → регистрацию одноразовой задачи `HermesNvDualGpuInstall` (`ONSTART`, SYSTEM) → перезагрузку.

После перезагрузки задача автоматически выполняет `pnputil /add-driver <inf> /install`, `pnputil /scan-devices`, устанавливает политику Windows Update и удаляет себя. Дождитесь окончания автозагрузки (1–3 минуты).

### Шаг 6. Проверить результат

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\patch-nv-dual-gpu.ps1 -Phase Verify
```

Ожидаемо: обе карты `DriverVersion = 32.0.15.8278`, `ConfigManagerErrorCode = 0`, обе в `nvidia-smi`.

### Шаг 7. Вернуть систему из тестового режима

Фаза `Prep` оставляет `testsigning on`. Для возврата в обычный режим:

```powershell
bcdedit /set testsigning off
shutdown /r /t 5
```

Проверка после перезагрузки:

```powershell
bcdedit /enum "{current}" | Select-String testsigning
bcdedit /enum "{default}"  | Select-String testsigning
```

Ожидаемо: `testsigning  No` в обоих хранилищах, водяной знак «Test Mode» отсутствует, обе карты остаются Code 0.

### Параметры

| Параметр | По умолчанию | Назначение |
|---|---|---|
| `-Phase` | `Prep` | `Prep` / `Install` / `Verify` / `Revert` / `DryRun` |
| `-TargetHwid` | `PCI\VEN_10DE&DEV_1F03&SUBSYS_886D1043` | hardware ID GeForce-карты |
| `-TargetName` | `NVIDIA GeForce RTX 2060` | имя в `[Strings]` |
| `-DonorHwid` | `DEV_1EB8` | датацентр-донор того же чип-семейства |
| `-AnchorHwid` | `DEV_1DB6` | маркер Tesla-карты в живом пакете |
| `-WorkDir` | `E:\AI\nv_dualgpu` | каталог копии пакета |
| `-NoReboot` | выключен | не перезагружать после `Prep` |

## Защита конфигурации

При установке ставится политика:

```
HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate
ExcludeWUDriversInQualityUpdate = 1
```

Windows Update не подменяет пакет драйвера. Откат: значение `0` или удаление параметра. Альтернатива — скрытие пакета драйвера через `wushowhide`.

## Ограничения

- Конфигурация не поддерживается NVIDIA и Microsoft.
- V100 (Volta) остановлена на ветке 580; ветки GeForce 590+ её не поддерживают. Обновление драйвера выполняется синхронно на обеих картах в пределах поддерживаемой обеими картами ветки, затем патч применяется заново.
- Установщик GeForce-драйвера NVIDIA поверх этой конфигурации заменяет общий `nvlddmkm.sys` и ломает Tesla-карту.
- После обновления Windows конфигурацию, как правило, требуется применять заново.
- Вывод на монитор, NVENC и G-SYNC на GeForce-карте через датацентровый драйвер не проверялись; CUDA и вычислительные нагрузки работают.
- Порядок индексов CUDA после добавления второй карты меняется; при необходимости фиксируется через `CUDA_VISIBLE_DEVICES`.

## Откат

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\patch-nv-dual-gpu.ps1 -Phase Revert
```

`pnputil /delete-driver oemNN.inf /uninstall /force` (oemNN ищется сканированием `C:\Windows\INF\oem*.inf` на целевой `DEV_`), удаление тестовых сертификатов `CN=Hermes Test Root CA` и `CN=Hermes NV Mod Signing` из `My` / `Root` / `TrustedPublisher` / `CA`, `bcdedit /set testsigning off`. После перезагрузки — установка официального GeForce-драйвера.

## Проверенное состояние после применения

```
NVIDIA GeForce RTX 2060      32.0.15.8278  Code 0
NVIDIA Tesla V100-PCIE-32GB  32.0.15.8278  Code 0

index, name, driver_version, memory.used [MiB]
0, NVIDIA GeForce RTX 2060, 582.78, 33 MiB
1, Tesla V100-PCIE-32GB,    582.78, 32332 MiB

bcdedit: testsigning No ({current}, {default})
Published INF: oem45.inf (32.0.15.8278, содержит DEV_1F03)
```
