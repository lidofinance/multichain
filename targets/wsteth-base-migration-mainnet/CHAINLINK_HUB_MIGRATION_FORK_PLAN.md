# План симуляции миграции mainnet hub pool силами Chainlink

Дата: 30 октября 2026 года. Статус: реализовано в fork-пайплайне target и выполнено 30.10.2026 (шаги 01h `hub-inventory`, 05h `hub-cutover` и 05c `hub-connect-lane`, тест `test/scenario/RealHubMigration.t.sol`, расширение state-mate; результаты прогонов — в [README](README.md), разделы «Status, 2026-10-30» и «Status, 2026-10-30, run 07»). Непроверенными остаются участки, для которых в target нет spoke-форков (см. «Изменения в репозитории»). Обновлено 30.10.2026 по итогам ревью (`tmp/chainlink-hub-plan-review.md`): приняты четыре решения ниже, условные формулировки заменены прочитанными фактами. Пятое решение того же дня: действие Chainlink разделено на два — пакет cutover переносит только существующие направления (hub в момент привязки повторяет старый пул), а направление Base на hub Chainlink подключает отдельным proposal в LidoTimelock после cutover и до создания голосования (шаг 05c; в explainer шаг 1b). 31.10.2026 план сверен с [планом апгрейда](docs/2026-10-26-upgrade-path.md), где те же действия вошли в раздел 1.2, и с explainer; проверка неизменности четырёх lockbox из шага 6 добавлена в `RealBaseMigration.t.sol` (README, раздел «Status, 2026-10-31»). 11.11.2026 план приведён к текущему состоянию старого пула: переносятся пять направлений с remote pool, четыре направления без remote pool остаются в старом пуле (раздел «Состав направлений»; README, раздел «Status, 2026-11-11»).


**Текущий порядок, 03.11.2026:** 1.1 `hub-prepare` → 1a `hub-cutover` →
`hub-accept-admin` через предложение MCMS → проверка hub → 1.2 `base-prepare` →
1b `hub-connect-lane` → голосование Base. До проверки hub существуют только четыре
lockbox текущих направлений; BaseLockBox, CCV-контракты для Base и три реализации
токена/мостов разворачиваются в 1.2. Деплоер теряет ADMIN_ROLE Ethereum в конце 1.1.
Описание старых прогонов ниже сохраняет их исторические ограничения; исполняемый порядок
и границы текущих проверок указаны в [README](README.md#pipeline-just-wsteth-all-after-just-wsteth-prepare-wsteth-base-migration-mainnet-run-id-fork).

Цель — заменить действующий Ethereum-пул wstETH новым `SiloedLockReleaseTokenPool 2.0.0`, перенести обеспечение существующих CCIP-направлений в lockbox-ы нового пула с сохранением нынешней изоляции (общий `ERC20LockBox` для unsiloed-направлений Monad и MegaETH, отдельные для трёх siloed) и завести отдельный `ERC20LockBox` для Base. Сначала репетируем миграцию Chainlink, затем, после проверки пяти перенесённых направлений на новом пуле, создаём голосование Base и запускаем уже существующий сценарий миграции legacy-моста.

Это расширение [текущей репетиции Base](README.md). Прежние результаты Base не доказывали перенос обеспечения и сохранение остальных направлений: до 30.10.2026 `07_set_pool_gov.sh` менял запись Ethereum-реестра на новый пул, настроенный только для Base. Теперь переключение записи делает шаг 05h пакетом Chainlink, а часть D шага 07 отказывается работать, если target объявляет миграцию hub (`.migration.hub` в `target.json`), но записи cutover нет.

## Решения 30.10.2026

| Вопрос | Решение | Основание |
| --- | --- | --- |
| Lockbox-ы для пяти переносимых направлений | Сохранить нынешнюю изоляцию: SharedLockBox для unsiloed (Monad, MegaETH), отдельные lockbox для Bitlayer, 0G и Robinhood; BaseLockBox для Base. Итого пять lockbox. Unsiloed-резерв старого пула переходит в SharedLockBox целиком | `SiloedLockReleaseTokenPool 2.0.0` допускает несколько селекторов на один lockbox и один селектор на свой; изоляция стоит один контракт на силос, модель риска существующих направлений не меняется |
| Migration helper | Не нужен: перенос обеспечения, `setPool` и `transferAdminRole` исполняются вызовами самого Chainlink timelock в одном batch | `withdrawLiquidity` и `withdrawSiloedLiquidity` 1.6.0 переводят токены `msg.sender`; timelock уже rebalancer всего, кроме силоса Bitlayer; `ERC20LockBox.withdraw` 2.0.0 считает баланс по `balanceOf`, поэтому обычный transfer засчитывается без `deposit` и без допуска |
| Порядок относительно голосования Base | Cutover (шаги 1–5) и проверка пяти направлений завершаются до создания голосования | внешняя зависимость от Chainlink уходит из таймеров T_activate_L1; сценарий «реестр не переключён к T_activate_L1» остаётся тестом отклонения, а не рабочим путём |
| CCV пяти переносимых направлений | В hooks нового пула для них нет требуемых CCV, как у пула 1.6.0 сегодня; dummy verifier только для Base и только в репетиции | поведение lane для существующих пользователей не меняется; реальные verifier Chainlink, если появятся, — отдельное изменение manifest |

Факты, прочитанные 30.10.2026 на блоке Ethereum 26 305 210 и из исходников (перечитать на pinned block репетиции):

- Старый пул `0xA586a732394A1AFfCF15b972cd47C936033C9FA7`: `typeAndVersion` «SiloedLockReleaseTokenPool 1.6.0»; owner и unsiloed rebalancer `0x44835bBBA9D40DEDa9b64858095EcFB2693c9449`; баланс 15 321,057 wstETH = unsiloed 15 276,445 + силосы Bitlayer 0,105, 0G 0,013, Robinhood 44,494 (dust 0). Rebalancer силосов 0G и Robinhood — тот же timelock, силоса Bitlayer — `0x2728df4D22253004C017675bd609962cD641D797`. Геттер — `getChainRebalancer(uint64)`; `getSiloRebalancer` в 1.6.0 нет.
- `setRebalancer(address)` и `setSiloRebalancer(uint64,address)` ревертят на нулевом адресе (`ZeroAddressNotAllowed`); `withdrawLiquidity(uint256)` уменьшает unsiloed accounting, `withdrawSiloedLiquidity(uint64,uint256)` — баланс силоса; оба требуют `msg.sender == getChainRebalancer(selector)` и переводят токены вызывающему. `transferLiquidity` в 1.6.0 отсутствует. Пауза ставится `setChainRateLimiterConfigs(uint64[],…)` одним вызовом.
- Chainlink timelock: `getMinDelay()` = 10 800 с (3 часа). TokenAdminRegistry: administrator timelock, pendingAdministrator 0, pool — старый пул.
- Пауза исходящих (проверено симуляцией на fork 30.10.2026): конфигурацию `{isEnabled: true, capacity: 1, rate: 0}` из руководства Chainlink пул 1.6.0 отвергает (`InvalidRateLimitRate`: при включённом лимите rate не может быть 0 и не может быть ≥ capacity); наименьшая допустимая — `{true, 2, 1}`, и ровно на ней Chainlink держит исходящие четырёх отключённых сетей: Ink, Plasma, Jovay и Abstract. Прогон 30.10.2026 подтвердил, что `withdrawLiquidity` и `withdrawSiloedLiquidity` переводят токены вызывающему: баланс timelock до и после пакета одинаков.
- Router Ethereum: исходящие всех направлений старого пула и Base через один OnRamp 2.0.0 `0xc3423F3FB30857D9C14717b119884b1B63d250b7`; входящие через общий OffRamp 2.0.0 `0x408428bca0e24A25ac8baAc1b70f64AF257717c3`, общий OffRamp 1.6.0 `0x26d3681DfC9E4c8C79cfbf461adec8A21d5d73C5` и старые OffRamp-ы отдельных источников (Bitlayer `0x3B45dd27E0cF84F1af98DEaBDc8f96303475ef58`, Ink `0x0F1B1A46AdeadF3C0D583AC86f40bC9e0b2e4Ba2`, Abstract `0x9f0E818A8DDDf48C52d5c94D55079E3617d55181`, Monad `0xfC92C3b8a374F70cb46cf884D4f02bb120f0F0a3`). `TokenPool 2.0.0` принимает V1-вызов `releaseOrMint(tuple)` и исполняет hooks в обоих путях.

## Целевая топология

```text
Ethereum TokenAdminRegistry: wstETH → новый hub pool 2.0
                                      │
                                      ├─ Monad, MegaETH → SharedLockBox
                                      │                           unsiloed-обеспечение старого пула
                                      ├─ Bitlayer   → BitlayerLockBox   (силос старого пула)
                                      ├─ 0G         → ZeroGLockBox      (силос старого пула)
                                      ├─ Robinhood  → RobinhoodLockBox  (силос старого пула)
                                      └─ Base       → BaseLockBox
                                                      обеспечение legacy-моста Base
```

Все пять lockbox находятся на Ethereum. На существующих удалённых сетях сохраняются их токены, пулы и записи TokenAdminRegistry. Меняется разрешённый адрес Ethereum-пула. На Base остаётся отдельный новый BurnMint-пул из существующего migration target.

Новый hub pool, его hooks и все пять lockbox принадлежат LidoTimelock. Четыре lockbox существующих направлений разрешают вызовы только новому hub pool. Base-lockbox дополнительно разрешает legacy-мосту Base получать обеспечение для незавершённых выводов в предусмотренное миграцией время. Legacy-мост не получает доступа к lockbox существующих направлений.

В локальном `SiloedLockReleaseTokenPool 2.0.0` отображение `chainSelector → lockbox` допускает несколько направлений на один адрес; `configureLockBoxes` и авторизацию пула уже выполняет [2_Configure.s.sol](../../components/ccip/chains/evm/contracts/lido-hvmv/script/deployment/2_Configure.s.sol).

**Изоляция сохраняется как есть.** Unsiloed-направления Monad и MegaETH делят SharedLockBox, как сегодня делят общий бакет старого пула; Bitlayer, 0G и Robinhood получают по своему lockbox, как сегодня свои силосы. Inventory обязан показать это разделение и суммы на pinned block; manifest фиксирует карту селектор → lockbox и сумму перевода в каждый. Изоляция Base проверяется независимо.

## Исходное состояние и воспроизводимость

Исторические адреса из репетиции, которые нужно заново подтвердить на выбранном блоке Ethereum:

| Объект | Адрес |
| --- | --- |
| wstETH | `0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0` |
| TokenAdminRegistry | `0xb22764f98dD05c789929716D677382Df22C05Cb6` |
| Старый hub pool | `0xA586a732394A1AFfCF15b972cd47C936033C9FA7` |
| Chainlink timelock, прежний владелец пула и администратор записи | `0x44835bBBA9D40DEDa9b64858095EcFB2693c9449` |

### Состав направлений

Состояние старого пула на блоке Ethereum 26 391 413 (11.11.2026): `getSupportedChains` возвращает девять сетей.

| Группа | Сети | Что делает миграция |
| --- | --- | --- |
| Подключённые: у сети есть remote pool | Bitlayer, 0G, Monad, MegaETH, Robinhood | hub pool принимает направление с теми же remote pool, remote token и лимитами |
| Отключённые: `getRemotePools` пуст | Ink, Plasma, Jovay, Abstract | остаются в старом пуле; hub pool их не обслуживает |

Отключённое направление не переносится, потому что переносить нечего: пул без remote pool отклоняет любой входящий перевод, а исходящий лимит этих четырёх сетей равен 2 wei. Пулы этих сетей тоже не содержат адреса Ethereum-пула. В обращении там остались тестовые суммы: Ink 0,00023 wstETH, Plasma 0,00019, Jovay 0,0001, Abstract 0,0238. Их обеспечение лежит в unsiloed-резерве и вместе с ним переходит в SharedLockBox. Повторное подключение такой сети — отдельный proposal в LidoTimelock: `applyChainUpdates` и `configureLockBoxes` на hub pool, `addRemotePool` на пуле сети.

Оба списка объявлены в `target.json`: `.migration.hub.expectedLanes` и `.migration.hub.disconnectedLanes`. Шаг 01h читает старый пул на pinned block и останавливается, если любой из списков не совпал: сеть появилась, исчезла, потеряла remote pool или получила его обратно. Изменение состава требует обновить target и manifest, а не исключить неизвестную сеть.

До изменений сохранить `inventory.before.json`:

- Номер, hash и timestamp блока каждой сети; chain ID и selector; версии исходников, compiler settings, ABI и codehash всех задействованных контрактов.
- TAR administrator, pendingAdministrator и pool; владельцев, реальные роли proposer/executor/admin и задержки timelock. Значение «3 часа» прочитано 30.10.2026 (`getMinDelay()` = 10 800 с на блоке 26 305 210); перечитать на pinned block.
- Все supported chains, remote tokens и remote pools, конфигурацию rate limits, доступных ramps, fees, finality и hooks/CCV. Зафиксировать, какие значения копируются и какие переводятся в формат 2.0.
- Баланс старого пула, unsiloed accounting, каждый siloed balance и соответствующих rebalancer (`getUnsiloedLiquidity()`, `getAvailableTokens(selector)`, `getChainRebalancer(selector)`). Сверить сумму учётных балансов с фактическим ERC20-балансом; отдельно разобрать прямые переводы и dust, если они есть. Эти суммы становятся аргументами batch шага 4.
- На каждом spoke — настоящий token/pool, его ABI, владелец и маршрут управления, запись TAR, разрешённые Ethereum remote pools, supply и mint/burn роли.
- Незавершённые CCIP-сообщения: source/destination, message ID, source block, сумма, source pool, состояние исполнения и финальность. Отдельно — legacy-сообщения Base.

Для полного прогона нужны forks Ethereum, Base и каждой существующей удалённой сети. Блоки фиксируются по согласованному временному срезу с учётом финальности и очереди сообщений. Если RPC или исторические данные недоступны, соответствующий участок обозначается как непроверенный; общий результат не получает статус полного прохождения. Текущий target поднимает только forks Ethereum и Base: шаг 01h записывает в inventory только то, что читается с Ethereum (пул, реестр, timelock, Router) и из API Chainlink (селектор → сеть и её инфраструктура CCIP); участки на spoke-ах перечислены в `state/hub-migration.json` под `unverified`.

## Исполнители и границы полномочий

| Исполнитель | Действия в репетиции |
| --- | --- |
| Deployer | Новый hub, пять lockbox, hooks; настройка и передача ownership. Migration helper не разворачивается |
| Chainlink через существующий Ethereum timelock | Пауза исходящих на старом пуле, затем один batch: вывод unsiloed и siloed ликвидности, временная смена rebalancer силоса Bitlayer, transfer в четыре lockbox, переключение TAR и номинация нового администратора. Без посредников: токены проходят через баланс timelock внутри одной транзакции |
| Владельцы существующих spoke-пулов | Добавление нового Ethereum remote pool, остановка и восстановление исходящих переводов; фактический владелец может отличаться от Chainlink |
| Lido DAO через LidoTimelock | Настройка нового стека после передачи ownership, принятие TAR administration, дальнейшая миграция Base |
| Исполнитель CCIP в тесте | Доставка сообщений с явно указанным уровнем симуляции |

Передача TAR administration и ownership старого пула — разные полномочия. План не передаёт старый пул Lido: Chainlink завершает операции со старым обеспечением своей текущей властью.

На fork разрешена impersonation фактического proposer/executor с выполнением настоящих `schedule`/`execute` и ожиданием задержки. Если слой MCMS подписей заменён impersonation, это указать в отчёте. Прямой `prank(timelock)` допустим для диагностики, но не заменяет основной тест governance-пакета. Не выдавать отсутствующие роли через запись storage.

## Порядок репетиции

### 1 Подготовить новый стек без переключения реестра

Развернуть hub 2.0 и пять lockbox: SharedLockBox, BitlayerLockBox, ZeroGLockBox, RobinhoodLockBox, BaseLockBox. `configureLockBoxes`: селекторы Monad и MegaETH → SharedLockBox; Bitlayer, 0G, Robinhood → каждый в свой lockbox. На каждом из пяти lockbox `applyAuthorizedCallerUpdates(+hub)`, BaseLockBox включительно. Существующие remote pool/token addresses и лимиты импортировать из inventory без изменений. Направление Base деплоер на hub не настраивает (решение 30.10.2026, `deferred_lanes` в hub-записи): ни `applyChainUpdates`, ни привязки BaseLockBox к селектору, ни записей CCV — так hub в момент cutover обслуживает ровно подключённые направления старого пула, а Base подключает Chainlink отдельным proposal после cutover (шаг 5a ниже). Не запускать deploy или ownership handover существующих spoke-пулов как для новых сетей. Генерация конфигурации расширена до inventory направлений старого пула (см. «Изменения в репозитории»).

Настроить лимиты, fees и hooks отдельно для старых направлений и Base. Для пяти переносимых направлений в hooks нет требуемых CCV: действует верификация lane Chainlink по умолчанию, как у пула 1.6.0 сегодня. Base dummy verifier остаётся только для Base и только в репетиции; на рабочие направления он не распространяется. Зафиксировать совместимость с текущими ramps: исходящие всех направлений идут через OnRamp 2.0.0, входящие — через OffRamp 2.0.0, 1.6.0 и старые OffRamp-ы отдельных источников; пул 2.0.0 принимает оба пути вызова, и hooks исполняются в обоих, поэтому пауза hooks распространяется на все пять направлений.

Передать ownership нового стека LidoTimelock и завершить принятие. До переключения TAR новый hub закрыт для пользовательских исходящих переводов; существующие направления продолжают работать через старый пул. Base CCIP остаётся закрытым до его отдельной готовности, независимо от LEGACY-режима мостов.

### 2 Подготовить существующие удалённые пулы

Через владельца каждого spoke-пула добавить новый Ethereum hub в список remote pools, сохранив старый. Выполнить вызов по ABI конкретной версии, а не предполагать одинаковый `addRemotePool` для всех.

Проверить обе стороны связи: новый hub признаёт действующий spoke-пул, spoke-пул признаёт новый hub. Старый hub пока остаётся зарегистрированным. Spoke TAR, token implementation и mint/burn роли остаются прежними.

Новый hub 2.0 с прежними spoke-пулами — проверяемое условие репетиции. Документация допускает постепенное обновление, но каждый фактический маршрут должен пройти тест, включая payload и принимающий ramp. [Руководство Chainlink](https://docs.chain.link/ccip/evm/concepts/cross-chain-token/lock-mint-v1-to-v2).

### 3 Остановить новые отправки и завершить очередь

Основной сценарий использует окно обслуживания: остановить исходящие переводы по всем существующим направлениям на Ethereum и spokes, оставив возможность доставить уже отправленные сообщения. На Ethereum это отдельный proposal timelock до пакета шага 4: `setChainRateLimiterConfigs([пять селекторов], outbound {isEnabled: true, capacity: 2, rate: 1}, inbound без изменений)` — пауза из руководства Chainlink по переходу v1 → v2 в виде, который принимает RateLimiter пула 1.6.0: значение `capacity: 1, rate: 0` из руководства контракт отвергает (`InvalidRateLimitRate`: при включённом лимите rate не может быть 0 и не может быть ≥ capacity; проверено симуляцией на fork 30.10.2026), а (2, 1) — наименьшая допустимая конфигурация, и ровно на ней Chainlink держит исходящие четырёх отключённых сетей: Ink, Plasma, Jovay и Abstract. На spoke-ах способ остановки подбирается по реальному ABI каждой версии. Проверять revert фактического `ccipSend`; не считать `isEnabled: false` паузой лимитера и не считать общий pause совместимым с доставкой входящих сообщений без теста.

Обязательная часть окна — пауза исходящих со spoke-ов на время между снятием сумм и исполнением batch: release по сообщению spoke → Ethereum уменьшает баланс старого пула, и `withdrawLiquidity` на снятую сумму ревертит. Остановка исходящих на Ethereum защищает только от остатка в старом пуле. Полное опустошение очереди — выбранный уровень консерватизма основного сценария, а не единственное условие корректности: сообщения, отправленные через старый пул до cutover, доходят по двойной записи remote pools (шаг 2).

Зафиксировать границу остановки и завершить все сообщения до неё. Один только `warp` на несколько часов или отсутствие новых логов не доказывает пустую очередь. Недостаток данных о старых сообщениях блокирует основной сценарий переноса всего баланса.

В отдельной ветке оставить сообщения в пути и проверить их обработку после переключения. Эта ветка проверяет восстановление; разрешение мигрировать с неизвестной очередью из неё не следует.

### 4 Выполнить атомарный пакет Chainlink на Ethereum

Для первой реализации **Chainlink сохраняет TAR administrator до переключения пула**. Это позволяет объединить перенос обеспечения и `setPool` в одной транзакции его timelock. Передача управления Lido выполняется после переключения. Такая последовательность заменяет прежнее «сначала transferAdminRole, потом accept + setPool».

Migration helper не нужен (решение 30.10.2026). `withdrawLiquidity` и `withdrawSiloedLiquidity` пула 1.6.0 переводят токены `msg.sender`; rebalancer unsiloed-бакета и силосов 0G и Robinhood — сам Chainlink timelock; `ERC20LockBox 2.0.0` в `withdraw` берёт `balanceOf(this)`, поэтому обычный ERC20 transfer в lockbox засчитывается без `deposit` и без допуска для отправителя. Весь перенос исполняется вызовами самого timelock. Helper остаётся запасным вариантом только если Chainlink откажется проводить wstETH через баланс timelock внутри одной транзакции; тогда он получает права rebalancer на время batch и теряет их в том же batch.

Preflight вне транзакции: manifest актуален (старый TAR pool/admin, учётные суммы unsiloed и каждого силоса на pinned block, привязки нового hub, адреса четырёх lockbox, `getLockBox(selector)` для пяти переносимых селекторов; Base ещё не подключён и BaseLockBox не развёрнут); исходящие остановлены на Ethereum и spoke-ах, очередь spoke → Ethereum пуста. Межсетевую готовность подтверждает отдельный preflight — Ethereum-транзакция сама не читает forks других сетей.

Пакет, один batch через настоящий Chainlink timelock (суммы — учётные балансы с pinned block):

1. `SiloedLockReleaseTokenPool.withdrawLiquidity(unsiloed)` — unsiloed-бакет приходит на timelock.
2. `withdrawSiloedLiquidity(4426351306075016396, silo0G)` и `withdrawSiloedLiquidity(6180753054346818345, siloRobinhood)` — rebalancer обоих силосов уже timelock.
3. `setSiloRebalancer(7937294810946806131, timelock)`, `withdrawSiloedLiquidity(7937294810946806131, siloBitlayer)`, `setSiloRebalancer(7937294810946806131, 0x2728df4D22253004C017675bd609962cD641D797)` — нулевой адрес setter не принимает, поэтому возвращается прежний rebalancer силоса; допустимый вариант — оставить timelock rebalancer-ом пустого силоса, выбор фиксируется в manifest.
4. `wstETH.transfer(SharedLockBox, unsiloed)`, `wstETH.transfer(BitlayerLockBox, siloBitlayer)`, `wstETH.transfer(ZeroGLockBox, silo0G)`, `wstETH.transfer(RobinhoodLockBox, siloRobinhood)`.
5. `TokenAdminRegistry.setPool(wstETH, newHub)` от прежнего администратора.
6. `TokenAdminRegistry.transferAdminRole(wstETH, lidoTimelock)`.

После исполнения проверить вне транзакции: нулевой остаток старого пула (ERC20-баланс, `getUnsiloedLiquidity`, `getAvailableTokens` по каждому силосу); баланс wstETH на timelock равен балансу до пакета; точный прирост каждого из четырёх lockbox; BaseLockBox ещё не развёрнут, Base legacy escrow не изменился; TAR `pool == newHub`, `pendingAdministrator == lidoTimelock`. Любой необъяснённый остаток прекращает основной сценарий. Суммы, снятые с pinned block, верны только при остановленных отправках (шаг 3): `withdrawLiquidity` на сумму больше учётной ревертит, на меньшую — оставляет остаток.

Вывод из старого пула доступен rebalancer, а владелец назначает его. Для siloed средств нужно учитывать отдельные балансы и полномочия; полный ERC20-баланс нельзя передать одним `withdrawLiquidity`, а `transferLiquidity` в 1.6.0 отсутствует. [Описание версий и siloed liquidity](https://docs.chain.link/ccip/tools/sdk/guides/cct/reference/pool-types).

Все вызовы входят в один batch: ошибка любого шага откатывает весь пакет, старый пул, реестр и lockbox остаются как были. Получатели transfer и суммы зашиты в calldata proposal. До отправки сравнить calldata и hash исполняемого batch с сохранённым proposal; кто у Lido подписывает manifest и кто сверяет hash перед исполнением — назвать в runbook.

### 5 Принять управление и открыть существующие направления

Chainlink завершает передачу управления отдельным предложением MCMS в LidoTimelock:
`acceptAdminRole(wstETH)` ставится в очередь, выдерживается задержка, затем любой адрес
исполняет предложение через CallProxy. MCMS имеет PROPOSER_ROLE; ADMIN_ROLE у Agent,
деплоер отказался от своей роли в 1.1. Голосование DAO и bypass деплоера для этого шага
не используются. Перед любым деплоем Base обязательна проверка `test-hub`.

Проверить TAR `administrator == LidoTimelock`, `pendingAdministrator == 0`, `pool == newHub`; ownership, lockbox ACL и все направления. Открыть существующие маршруты, восстановив согласованные лимиты без случайного увеличения доступного burst. Провести round trip каждой сети. Старый Ethereum remote pool сохранять разрешённым, пока тест очереди и recovery не подтверждает возможность удаления.

### 5a Подключить направление Base на hub

После cutover hub принадлежит LidoTimelock, поэтому направление Base на нём — не часть пакета Chainlink из шага 4, а отдельное действие Chainlink другим инструментом: proposal в LidoTimelock от имени Chainlink MCMS (PROPOSER_ROLE), задержка `governance.min_delay_seconds` (3 суток), исполнение через CallProxy любым адресом. Содержимое proposal — ровно то, что `2_Configure` применил бы для Base и не применил: `applyChainUpdates([], [Base])`, `applyTokenTransferFeeConfigUpdates([Base], [])`, `configureLockBoxes([(Base, BaseLockBox)])`, `applyCCVConfigUpdates([Base])` на hooks, `applyRemoteChainConfigUpdates([Base])` на верификаторе, `applyOutboundImplementationUpdates([Base])` на resolver. На репетиции batch строит скрипт компонента `4_ConnectLane.s.sol` из тех же записей, шаг 05c сверяет его с записями (spoke pool и токен Base, BaseLockBox, адресаты только hub, hooks, verifier и resolver, ни одного заблокированного селектора) до `scheduleBatch` и читает направление после исполнения: девять старых направлений, балансы всех lockbox и запись реестра не меняются.

Известное окно: пока Base не исполнил action set (шаг 6 этого плана, шаг 06 пайплайна), отправка wstETH на Base через CCIP блокирует токены в BaseLockBox, а доставка на Base не исполняется до регистрации пула и выдачи ролей; голосование создаётся сразу после этого шага. Не отрепетированный вариант: подключить направление с исходящим лимитом `{true, 2, 1}` и открыть его отдельным proposal после action set Base. Лимиты Base и resolver вместо dummy — параметры mainnet.

### 6 Присоединить миграцию Base

Голосование Base создаётся только после завершения шагов 4–5a и проверки пяти направлений на новом hub (решение 30.10.2026): в happy path `activate()` на L1 всегда видит новый hub в реестре, а сценарий «реестр не переключён к T_activate_L1» остаётся тестом отклонения. Затем выполнить текущий Base upgrade/vote и активации. Base escrow поступает исключительно в BaseLockBox через `L1MigrationBridge.activate()`. Проверить, что ни один старый маршрут не меняет этот баланс, а Base-переводы не расходуют ни один из четырёх lockbox существующих направлений.

Таймер Base сам по себе не доказывает готовность Ethereum. В happy path L2 activation следует за успешной L1 activation и проверкой обеспечения: направление Base на hub к этому моменту уже подключено (шаг 5a), но CCIP-выводы с Base начинаются только с L2 activation, а BaseLockBox наполняет только L1 activation. Отдельно воспроизвести задержку L1 и раннюю попытку L2 activation: текущие контракты не обеспечивают межсетевой порядок автоматически. Проверить своевременное действие Emergency Brakes и восстановление; не записывать этот риск как устранённый одним новым hub pool.

После Base activation повторить весь [RealBaseMigration.t.sol](test/scenario/RealBaseMigration.t.sol), добавив проверки неизменности четырёх lockbox существующих направлений при legacy replay, rollback и close Base. Сделано 31.10.2026: каждая проверка сохранения средств в сценарии сверяет и балансы четырёх lockbox.

## Проверки и критерии прохождения

| Сценарий | Требуемое доказательство |
| --- | --- |
| Атомарный перенос | Revert на каждом существенном шаге оставляет старые TAR, баланс, rebalancer и новые lockbox в исходном состоянии |
| Полнота конфигурации | Ни одно подключённое направление не потеряно; unsiloed selectors Monad и MegaETH ведут в SharedLockBox, Bitlayer, 0G и Robinhood — каждый в свой lockbox, Base — в BaseLockBox; пять разных адресов, `getLockBox` совпадает с manifest для шести селекторов; четыре отключённые сети hub pool не обслуживает |
| Полномочия | Чужой caller не выводит средства из lockbox; proposer не обходит delay timelock; batch не исполняется повторно, получатели transfer и суммы зашиты в calldata |
| Все старые маршруты | Реальный Router/OnRamp принимает отправки, соответствующий пул выпускает/выдаёт точную сумму в обе стороны, роли и токены spokes сохранены |
| Плохая подготовка | Пропущенный remote pool, неверный selector, непрофинансированный lockbox, несовместимые hooks и неверные лимиты обнаруживаются до открытия отправок |
| Переводы в пути | Старый L1→spoke и старый spoke→L1 перевод завершаются после cutover; failed delivery допускает корректный retry; преждевременное удаление old remote pool воспроизводимо ломает доставку |
| Изоляция Base | Base bridge не может вывести ни из одного lockbox существующих направлений; исчерпание BaseLockBox не расходует их балансы и наоборот |
| Учёт средств существующих направлений | Обслуживание Monad или MegaETH уменьшает SharedLockBox (общий риск unsiloed-сетей, как в старом пуле); обслуживание Bitlayer, 0G или Robinhood меняет только их lockbox и не может расходовать SharedLockBox |
| Base integration | Старые направления продолжают работать до и после vote, activate, close и recovery Base |
| Повтор запуска | Завершённый этап распознаётся по состоянию; не выполняется второй sweep, deploy или handover после частичного сбоя orchestration |

На замороженном checkpoint до/после транзакции Chainlink:

```text
delta SharedLockBox    = -delta oldPool.unsiloed
delta BitlayerLockBox  = -delta oldPool.silo(7937294810946806131)
delta ZeroGLockBox     = -delta oldPool.silo(4426351306075016396)
delta RobinhoodLockBox = -delta oldPool.silo(6180753054346818345)
delta BaseLockBox = 0
delta BaseLegacyEscrow = 0
delta balance(chainlinkTimelock) = 0
oldPool_before + Σ lockboxes_before = oldPool_after + Σ lockboxes_after
```

Равенства проверяются только на замороженном checkpoint: между proposal и execute они не держатся при живом трафике (поэтому шаг 3), а после cutover балансы lockbox меняются с каждым переводом. State-mate после репетиции сравнивает не абсолютные значения, а изменение относительно checkpoint минус подтверждённые переводы из журнала.

В миграционной транзакции не происходит mint/burn на spokes. Для subsequent transfers хранить журнал изменений supply и переводов в пути; проверять сохранение обеспечения относительно исходного checkpoint. Абсолютное равенство «весь supply всех сетей = баланс hub» применять только после подтверждения полного охвата источников выпуска и очередей. Обеспечение Base и общий пул вести отдельными регистрами; при обнаружении spoke→spoke маршрутов включить их сообщения и изменения обязательств в тот же учёт.

Тест через impersonated OffRamp и прямой `releaseOrMint` доказывает работу pool boundary, но не DON, replay protection или полный формат сообщения. Отдельный transport-тест должен пройти реальный OffRamp execution с валидным для выбранного harness report/proof и проверить запрет двойного исполнения. Если этот уровень недоступен, результат обозначается как неполная проверка транспорта; синтетический message ID не выдаётся за доказательство совместимости старых сообщений.

## Остановка и восстановление

- До атомарного cutover: прежний пул остаётся зарегистрированным и обеспеченным. Отменить незавершённые proposals, проверить очередь и восстановить исходящие переводы со старыми лимитами.
- При revert cutover: подтвердить полный откат балансов и настроек; исправить причину и перепланировать batch с актуальным manifest.
- После успешного cutover: сначала остановить новые отправки, сохранить доставку и устранить конфигурационную ошибку на новом стеке. Один `setPool(oldPool)` не является rollback: старый пул уже пуст. Единственное окно одностороннего отката Chainlink — до `setPool` внутри batch (revert); сразу после него откат двусторонний: запись может вернуть Chainlink, пока LidoTimelock не принял администрирование, а обеспечение из lockbox возвращает только LidoTimelock (`applyAuthorizedCallerUpdates` + `withdraw`).
- Обратный перенос после cutover — отдельный тестируемый пакет с новым учётом обязательств, очередью, возвратом средств и полномочий. После handover его выполняют совместно Lido и Chainlink; после Base activation нельзя вернуть запись в старый пул без решения для Base.

## Изменения в репозитории

Состояние на 30.10.2026 (что из перечисленного сделано и чем):

1. Inventory collector и manifest — сделано: [01_hub_inventory.sh](../../orchestration/wsteth-ccip/script/01_hub_inventory.sh) (recipe `hub-inventory`) читает старый пул на pinned block и пишет `state/hub-migration/inventory.json` и `manifest.json` (карта селектор → группа lockbox, суммы на каждый lockbox, `siloRebalancerAfterCutover` из `target.json`). Существующие spokes представлены импортируемыми записями `config/chains/<slug>.json`, которые ничего не деплоят. Состав направлений сверяется с `.migration.hub.expectedLanes`; расхождение останавливает run.
2. Профиль миграции hub — сделано без отдельного профиля: `target.json` объявляет `.migration.hub`, и те же шаги пайплайна строят hub с десятью направлениями. Генерация конфигурации заменена: `remote_lanes` hub-записи получают девять направлений с `is_siloed` из старого пула (один общий lockbox на unsiloed, свой на каждый siloed — так `1_Deploy` компонента и строит пять lockbox), новый блок `imported_lanes` записи передаёт в `2_Configure` компонента удалённые пулы и лимиты старого пула и запрещает CCV для этих направлений, а список `deferred_lanes` (Base) велит `2_Configure` не настраивать направление, оставив его владельцу (изменение компонента `components/ccip`: `ConfigParser.sol`, `2_Configure.s.sol`, новый `4_ConnectLane.s.sol`, описание в его `config/README.md`, тесты парсера).
3. Генератор proposal и replay — сделано: [05_hub_cutover.sh](../../orchestration/wsteth-ccip/script/05_hub_cutover.sh) (recipe `hub-cutover`) проверяет, что hub обслуживает ровно девять направлений manifest и ничего больше, строит два proposal (пауза; пакет шага 4 с predecessor = пауза) и исполняет их через настоящий Chainlink RBACTimelock на fork; `state/hub-migration.json` хранит для каждого `target`, `value`, `data`, расшифровку, predecessor, salt, delay, id, proposer, executor, tx и блоки, а также снимки до/после, направления hub в момент cutover, результат проверки `ccipSend` и список непроверенного. Helper не реализован. Подключение Base (шаг 5a) — [05c_hub_connect_lane.sh](../../orchestration/wsteth-ccip/script/05c_hub_connect_lane.sh) (recipe `hub-connect-lane`): batch от `4_ConnectLane`, проверка его против записей, proposal в LidoTimelock от impersonated `governance_addresses.chainlink_mcms`, исполнение через CallProxy, чтение направления после; запись `state/hub-lane-connect.json` и сам batch в `state/hub-lane-connect/`. Жизненный цикл proposal на обоих timelock — общая функция `timelock_propose_and_execute` в `_common.sh`.
4. Шаг 07 — сделано: часть D отказывается работать, если target объявляет `.migration.hub`, а записи cutover нет; после шага 05h D пропускается (администрирование уже pending), E только принимает, пул уже привязан пакетом Chainlink.
5. `test/scenario/RealHubMigration.t.sol` — сделано для Ethereum: одиннадцать тестов (конечное состояние cutover; release и lock каждого из девяти направлений строго в свой lockbox; изоляция siloed-направлений от общего lockbox и Base от всех; невозможность повторного исполнения пакета; пауза старого пула; отсутствие требуемых CCV на девяти направлениях при сохранённом resolver у Base; hub в момент cutover обслуживал ровно направления старого пула; направление Base подключено proposal в LidoTimelock, который исполнен и повторно не исполняется). Сообщения в пути и spoke-сторона не покрыты: spoke-форков в target нет.
6. State-mate — сделано: `render-multichain-state.cjs` принимает общий lockbox для unsiloed-направлений, добавляет проверки остальных lockbox (owner, token, callers) и для импортируемых направлений — удалённые пулы, токен, лимиты, карту lockbox, пустые конфигурации CCV; `ccv-policy.cjs` понимает направления без требуемых CCV (`outbound: [], inbound: []`, `localResolver.outbound: "none"`). Прогон 30.10.2026: 338 проверок.
7. Отчёт — раздел «Status, 2026-10-30» в [README](README.md); transport checks на реальном OffRamp execution не выполнялись (см. «Проверки и критерии прохождения»).
8. Разделение действий Chainlink — сделано 30.10.2026 (прогон `hub-fork-20261030-07`, раздел «Status, 2026-10-30, run 07» в README): hub в момент привязки повторяет старый пул (шаг 05h это проверяет до `scheduleBatch`), направление Base подключается шагом 05c отдельным proposal в LidoTimelock; шаг 08 архивирует `hub-migration.json`, `hub-lane-connect.json` и batch. Прогоны 05 и 06 того же дня остановились внутри 05c на двух ошибках скрипта (helper без аргумента; четырёхаргументный `getTokenTransferFeeConfig` пула 2.0.0 и аннотации чисел в выводе `cast`), cutover и proposal на них исполнились верно. Открыто для mainnet: лимиты направления Base, resolver вместо dummy, порядок относительно голосования (подключить открытым, как на репетиции, или с закрытым исходящим лимитом и открыть после action set Base).
9. Сценарий Base при пяти lockbox — сделано 31.10.2026: `RealBaseMigration.t.sol` на каждой из одиннадцати проверок сохранения средств сверяет балансы общего lockbox и lockbox Bitlayer, 0G и Robinhood с начальными; оба сценарных файла прогнаны заново на форках прогона 07 (11 + 2 теста). Не сделано: round trip девяти направлений после активаций, close и откатов Base (критерий «Base integration»; тест hub работает в состоянии T_vote_L1) и на тот момент отдельный governance-тест принятия TAR administration proposal-ом LidoTimelock вместо bypass (шаг 5). Этот второй пробел закрывает текущий `hub-accept-admin` и тест принятия/replay; историческая репетиция 31.10 использовала bypass деплоера в шаге 07 после 05c.
10. Отключённые направления — сделано 11.11.2026 (прогон `disconnected-lanes-20261111-03`, раздел «Status, 2026-11-11» в README): пункты 2, 3 и 5 выше описывают прогоны 30.10.2026, когда remote pool был у всех девяти сетей. Теперь шаг 01h делит сети старого пула на подключённые и отключённые и сверяет оба списка с `target.json`; hub строится для пяти направлений, шаг 05h проверяет ровно их, `RealHubMigration.t.sol` дополнительно проверяет, что hub не обслуживает отключённые сети.

Перед написанием mainnet calldata implementation preflight обязан подтвердить: ABI и владельцев каждого spoke-пула и исполнимость паузы на каждом из них (ABI старого пула на Ethereum уже подтверждён по байткоду, см. факты выше); реальные governance principals нового стека; совместимость ramps на pinned block; покрытие всех remote RPC; полноту учёта очереди. До этого суммы остаются параметрами manifest, а список batch-вызовов шага 4 — зафиксированной формой пакета.

## Артефакты результата

Сохранить в отдельном `runs/wsteth-2.0/workspaces/<run-id>/` pinned inventory, версии кода, manifest, deployment receipts, proposal JSON и batch hashes, execution traces, снимки до/после каждого этапа, message ledger, результаты тестов/state-mate и краткий отчёт по каждой сети.

Отчёт отдельно отмечает: прошедшие проверки custody/governance, покрытие транспорта, заменённые подписи/relayers/verifiers и непроверенные направления. Пакет для Chainlink включает конкретные действия их Ethereum timelock и отдельные действия владельцев spoke-пулов с зависимостями. Успешная репетиция требует точного сохранения средств, всех прежних направлений и отдельного обеспечения Base; выполнение этого плана на публичных сетях не входит в fork-работу.
