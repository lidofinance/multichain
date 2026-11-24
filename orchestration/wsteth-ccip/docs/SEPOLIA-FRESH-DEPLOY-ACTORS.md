# Полномочия свежего Sepolia-деплоя

Профиль для Sepolia (11155111), Base Sepolia (84532) и Mantle Sepolia (5003). **Публичный деплой выполнен 2026-11-04.** Адреса токенов, подтверждённые назначения прав и результаты проверок находятся в [отчёте публичного деплоя](SEPOLIA-FRESH-DEPLOY-2026-11-04.md). Ниже описаны управляющие аккаунты и способы проверки их полномочий. JSON этого профиля сохранён как исходный вход зафиксированного run; его поле статуса не является журналом исполнения.

## Аккаунты и хранение ключей

Используется существующая `ACTORS_MNEMONIC` из локального `.env`, путь `m/44'/60'/0'/0/{index}`, пустая дополнительная BIP39 passphrase. Deployer использует отдельный `DEPLOYER_PRIVATE_KEY`. Все 18 ключей проверены локальной подписью и восстановлением адреса. Совпадений с первыми 20 аккаунтами стандартных Anvil/Hardhat и двух Ganache mnemonic, а также ключами 1 и 2 нет.

Ключи находятся в `.private/wsteth-testnet-2026-11-04/keys.env`: открытый текст, файл `0600`, каталоги `0700`, Git игнорирует его. Mnemonic не менялась. Run snapshots содержат только публичный JSON, без ключей. Скрипты выводят адреса и хеши транзакций, не ключи. Источник ключей для операций — исходный `.env`; экспорт нужен для локального доступа и восстановления соответствия ролей.

| Аккаунт | Индекс | Адрес | Переменная экспорта |
|---|---|---|---|
| Deployer / guardian L2 executor | отдельный | `0xE528a15071E6C5aF0C1ed8e6Ec647Ce9EC510597` | `DEPLOYER_PRIVATE_KEY` |
| Резерв, без назначенных прав | 0 | `0xd994024e2F9c9d8B199b4564223ad9807aAD1434` | `RESERVE_0_PRIVATE_KEY` |
| Emergency Brakes | 1 | `0x608056b8d596da5816146014E88DFfDECAF59DcD` | `EMERGENCY_BRAKES_PRIVATE_KEY` |
| Тестовый Chainlink proposer | 2 | `0x1D72FbCcfC86C88E23771d6D58a8F1Cb77186d1d` | `CCIP_PROPOSER_PRIVATE_KEY` |
| Держатель TLDO / DAO voter | 3 | `0x895B7d7020C2205FfA957385541616458Fe7911a` | `DAO_VOTER_PRIVATE_KEY` |
| DG reseal committee | 4 | `0x56f61794A722a55Dfe248abFE3f8D1cB741e3Fd6` | `DG_RESEAL_PRIVATE_KEY` |
| DG emergency governance proposer | 5 | `0x7596742254E4c9383280d4E8609E667F81f8bc86` | `DG_EMERGENCY_PROPOSER_PRIVATE_KEY` |
| DG emergency activation committee | 6 | `0x7B3C72102598A3b6027F56C1b920c4076f11CCA7` | `DG_EMERGENCY_ACTIVATION_PRIVATE_KEY` |
| DG emergency execution committee | 7 | `0xc8bD77bb45136eD4B67870feF0Fd05DD4A174B3A` | `DG_EMERGENCY_EXECUTION_PRIVATE_KEY` |
| DG tiebreaker: участник подкомитета 1 | 8 | `0x5a09cccE4f017642C948C3CB4c432DCb839d873c` | `DG_TIEBREAKER_1_PRIVATE_KEY` |
| DG tiebreaker: участник подкомитета 2 | 9 | `0x81545fAAB0b3D13cd163Df300bB7c4aE3b6395C2` | `DG_TIEBREAKER_2_PRIVATE_KEY` |
| DG tiebreaker: участник подкомитета 3 | 10 | `0x427e84566d6530E0d036542D17f32E15e16ef516` | `DG_TIEBREAKER_3_PRIVATE_KEY` |
| oracle_1 | 11 | `0xB4D2adF6C1193400C6b1EAE84f106CB0F38E8196` | `ORACLE_1_PRIVATE_KEY` |
| oracle_2 | 12 | `0xFb2E706C56Bc4EF56563EA172D63149ed451F424` | `ORACLE_2_PRIVATE_KEY` |
| oracle_3 | 13 | `0x6cC2F69ceABE65532BD949e1Ae9C2c4127Eb1936` | `ORACLE_3_PRIVATE_KEY` |
| dsm_guardian_1 | 14 | `0x8516da7118f3cA9a587ae79d09Bfd59a44D50623` | `DSM_GUARDIAN_1_PRIVATE_KEY` |
| dsm_guardian_2 | 15 | `0xaa2EcD6E3073dA9543145a85A3aAFF8d9c5f22d7` | `DSM_GUARDIAN_2_PRIVATE_KEY` |
| dsm_guardian_3 | 16 | `0x3F3785D2433EeADF785e33e20200b33F1F42E80a` | `DSM_GUARDIAN_3_PRIVATE_KEY` |

Все производные аккаунты зависят от одной mnemonic: это управляемый тестовый стенд, а не независимые операторы production. Резерв index 0 не получает постоянных прав. TLDO voter получает весь начальный выпуск **1 000 000 TLDO**; deployer и стандартные получатели upstream TLDO не получают. Proposer index 2 эмулирует Chainlink MCMS нашим EOA.

## Задержки

Источник: [access-profile.json](../../../targets/wsteth-ccip-sepolia-mantle-dev/config/access-profile.json). Применяется только к этому scratch target; Mainnet migration и Sepolia migration не наследуют профиль.

| Путь / ограничение | Настройка | Суммарное обязательное ожидание |
|---|---|---|
| Voting | 300 s, objection phase 60 s внутри Voting | 5 минут |
| Voting → DG → AdminExecutor → Agent | Voting 300 + после submit 120 + после schedule 120 s | 9 минут |
| Тот же путь → messenger → L2 executor | Executor 0 s | **9 минут**, доставка между сетями отдельно |
| CCIP proposer → LidoTimelock → CallProxy | 300 s | **5 минут** |
| DG emergency mode / tiebreaker execution | 300 s каждый | Отдельные аварийные процедуры |
| DG veto / rage quit: отдельные интервалы | 180–600 s | Не обычный путь; ожидания состояния и выхода валидаторов могут складываться |
| CircuitBreaker pause | 300 s, допустимый максимум 600 s | 5–10 минут |
| LazyOracle quarantine, NOR/SDVT penalty | 300 s | 5 минут |
| Consolidation batch execution delay | 0 s | Дополнительного ожидания нет |
| AO/VEBO frame | 1 epoch при 12 s × 32 slots | 384 s |
| Top-up block distance | 25 блоков Sepolia | Около 5 минут при 12 s/block |

Задержки стенда не увеличиваем относительно соответствующих mainnet-настроек: нулевое ожидание сохраняется нулевым. Для Bridge Executor исходные [Optimism](../../../components/core/foundry/lib/state-mate/configs/optimism/wsteth-mainnet.yaml) и [Mantle](../../../components/core/foundry/lib/state-mate/configs/mantle/mantle-mainnet.yaml) конфигурации задают `delay = 0`, `minimumDelay = 0`, `maximumDelay = 1 s`. Эти значения применяются и на Base Sepolia, и на Mantle Sepolia. Максимум — граница последующей настройки, а не текущее ожидание; `max = 0` при `min = 0` не допускает конструктор. Профиль отклоняет ненулевой `l2Executor`.

Budget относится к сумме обязательных ожиданий обычной governance-операции. Это верхний предел, а не требование добавлять ожидание до 5–10 минут. Время включения транзакций, действия оператора и доставка между сетями не имеют жёсткой верхней границы. На форках время продвигается средствами Anvil; на публичной сети скрипт ждёт реальные timestamps. Отдельный прямой Voting-путь остаётся короче: 5 минут.

Expiry предложения и execution grace — **окна исполнения по 1 дню**, а не задержки. ENS registration, срок действия emergency protection и heartbeat validity также не являются обязательным ожиданием. Внешние задержки CCIP/Nethermind, finality и реальные beacon validator exits этим профилем не изменяются.

### Сравнение с testnet-defaults Core и Dual Governance — 2026-11-04

Это сравнение локальных исходных конфигураций, а не readback публичных сетей. Выбранные значения применены в orchestration-профиле и генераторе параметров; исходные Core/DG defaults сохранены. Источники: [Core scratch defaults](../../../components/core/scripts/scratch/deploy-params-testnet.toml), [DG Hoodi](../../../components/core/foundry/lib/dual-governance/deploy-config/deploy-config-hoodi.toml) и [DG Holesky](../../../components/core/foundry/lib/dual-governance/deploy-config/deploy-config-holesky.toml). В двух DG-файлах перечисленные временные параметры совпадают; отдельного DeskNet-конфига в этих checkout не найдено. Колонка «Стенд» учитывает профиль и преобразования в [prepare.cjs](../script/testnet/prepare.cjs).

| Параметр | Core scratch default | DG Hoodi / Holesky | Стенд сейчас |
|---|---|---|---|
| Voting / objection phase внутри Voting | 5 мин / 1 мин | Не задаются | 5 мин / 1 мин |
| DG после submit | 15 мин | 2 мин | 2 мин |
| DG после schedule | 15 мин | 2 мин | 2 мин |
| `minExecutionDelay`, нижняя граница суммы двух DG delays | 10 мин | 2 мин | 4 мин |
| Tiebreaker activation / execution | 15 мин / 15 мин | 15 мин / 15 мин | 5 мин / 5 мин |
| Emergency mode duration | 1 час | 1 день | 5 мин |
| Min assets lock / veto signalling min | 5 мин / 5 мин | 5 мин / 5 мин | 5 мин / 5 мин |
| Veto signalling min active | 5 мин | **3 мин** | **3 мин** |
| Veto signalling max | 30 мин | 30 мин | 10 мин |
| Veto signalling deactivation max | 10 мин | 5 мин | 5 мин |
| Veto cooldown | 10 мин | **3 мин** | **3 мин** |
| Rage quit extension | 15 мин | **3 мин** | **3 мин** |
| Rage quit ETH withdrawals min / max delay | 5 / 30 мин | 10 / 60 мин | 5 / 10 мин |
| Rage quit ETH withdrawals delay growth | 10 мин | 20 мин | 5 мин |

`minExecutionDelay` проверяет допустимость настроек, не добавляет третье ожидание. Продолжительности veto / rage quit / emergency относятся к отдельным состояниям и процедурам; они не включены в обычный путь без veto.

| Другие параметры Core | Core scratch default | Стенд сейчас |
|---|---|---|
| Consolidation batch execution delay | **0** | **0** |
| CircuitBreaker initial pause / maximum | 21 день / 60 дней | 5 мин / 10 мин |
| LazyOracle quarantine | 3 дня | 5 мин |
| NOR / Simple DVT stuck penalty | 2 дня / 5 дней | 5 мин / 5 мин |
| AO / VEBO oracle frame | 12 / 4 epochs: 76 мин 48 с / 25 мин 36 с | 1 epoch: 6 мин 24 с для обоих |
| Top-up minimum block distance | 75 блоков, около 15 мин | 25 блоков, около 5 мин |

Время для epochs / блоков рассчитано при 32 slots/epoch и 12 s/slot. DSM pause-intent validity уменьшена с 6646 до 50 блоков; это срок действия подписи, не ожидание перед операцией. Consolidation delay сохраняет Core testnet-default 0; [mainnet deployment parameter](../../../components/core/scripts/archive/srv3-mainnet/upgrade-params-mainnet.toml) равен 86400 s.

Применённый вариант: Voting **5 минут**, objection **1 минута** из Core, DG **2 + 2 минуты** из его testnet-конфига и executor **0**. Сумма обязательных governance-задержек на L1 и L2 — **9 минут**, без доставки сообщения. Копирование всего Core default дало бы 35 минут. Три DG-интервала, выделенные выше, возвращены к 3 минутам, consolidation delay — к 0.

## Кто управляет каждым классом полномочий

В таблице «DAO Agent» означает подписанный путь voter → TokenManager → Voting → DG → EmergencyProtectedTimelock → AdminExecutor → Agent. Для L2 к нему добавляются настоящий L1 messenger, доставка сообщения, L2 messenger и executor. Guardian L2 умеет отменять операции, но не заменяет этот путь.

| Объект / действие | Держатель / способ выполнения |
|---|---|
| Core: 18 DEFAULT_ADMIN_ROLE, 15 proxy-admin, DSM owner, stakingVaultBeacon owner | DAO Agent. `core-access` передаёт beacon от deployer и снимает его MANAGE_ROLE / ADD_CONSOLIDATION_REQUEST_ROLE / ALLOW_PAIR_ROLE на consolidation contracts |
| Core operational role, которой пока никто не владеет | DAO Agent выдаёт роль в том же batch, выполняет действие, отзывает временную роль; наличие DEFAULT_ADMIN_ROLE само по себе не даёт operational role |
| Aragon Kernel APP_MANAGER, Finance, EVMScriptRegistry, настройки Voting, withdrawalVault proxy admin | **Прямое Voting**, без DG/Agent: route `voting`. Для конкретного приложения сверять его ACL и manager |
| Agent RUN_SCRIPT_ROLE / EXECUTE_ROLE | AdminExecutor; permission manager — Agent. Обычная операция использует Agent.forward |
| DG настройки, комитеты, EmergencyProtectedTimelock | **AdminExecutor**, route `admin-executor`; вызов от Agent не заменяет этот адрес |
| LidoTemplate и SepoliaDepositAdapter owner | Agent после upstream handover; проверить наличие adapter в конкретном run |
| Scratch ENS/APM инфраструктура | Контролируемый deployer сохраняет исходные инфраструктурные полномочия; это не дополнительные права на токен или pool |
| AO / VEBO HashConsensus | Три oracle key index 11–13, quorum 2. Frame запускается `core-access`; состав и quorum меняет Agent через соответствующую роль |
| DSM | Три контракта TestnetDsmGuardian (ERC-1271), подписанты index 14–16, quorum 2 для депозитов. EOAs напрямую DSM не принимает; signer каждого адаптера immutable, замена guardian — через Agent. Для emergency pause достаточно одного guardian; unpause — Agent |
| Core пауза | Emergency Brakes: PAUSE_ROLE / STAKING_PAUSE_ROLE Lido. CircuitBreaker регистрирует его для WithdrawalQueue и VEBO. CB pause расходует регистрацию; Agent повторно регистрирует pauser |
| DG reseal | Index 4 → DualGovernance.resealSealable; разрешён только в соответствующем состоянии DG |
| DG emergency | Index 6 активирует, index 7 выполняет emergency operations/reset; index 5 подаёт предложения в emergency governance после переключения |
| DG tiebreaker | Три подкомитета по одному ключу index 8–10, outer quorum 2. Решение требует подходящего состояния DG и выполнения обоих уровней комитета |
| CCIP LidoTimelock ADMIN_ROLE | L1 Agent / соответствующий L2 executor. Restart очереди, смена ролей, admin bypass |
| CCIP PROPOSER_ROLE / CANCELLER_ROLE | Index 2. Schedule → 300 s → CallProxy.executeBatch. Запрещённые селекторы, включая role/ownership/upgrade, требуют DAO admin bypass |
| CCIP emergency pause/cancel/halt | Index 1: hooks PAUSE, timelock CANCELLER и PROPOSAL_QUEUE_HALT. Restart — только DAO admin; hooks unpause — owner через proposal либо bypass |
| CCIP EXECUTOR_ROLE | CallProxy; любой аккаунт может исполнить готовую разрешённую операцию |
| Pool: lanes, remote pools/tokens, rate limits, router/fees, hooks | Owner — LidoTimelock. rateLimitAdmin и feeAdmin изначально нулевые; владелец управляет настройками |
| Hooks: CCVs, thresholds, policy engine, pausers, disabled lanes | Owner — LidoTimelock. UNPAUSE_ROLE отдельно не выдан, owner может unpause |
| Hooks sender allowlist | Флаг immutable; исходно disabled. Для включения нужен **новый hooks** с непустым allowlist, перенос конфигурации, acceptance ownership и смена pool pointer; `access-ops replace-hooks` готовит этот путь |
| L1 lockboxes | Owner — LidoTimelock, но withdraw требует authorized caller. `lockbox-plan` добавляет timelock, выводит ликвидность и удаляет временное разрешение **одним atomic batch** |
| Dummy verifier / VersionedVerifierResolver | Owner — LidoTimelock: endpoints, fees, allowed callers/signers и routing. Dummy allowlistAdmin = 0: управление через owner. FeeAggregator — Agent / L2 executor |
| TAR: наш токен | Administrator — LidoTimelock, pendingAdministrator = 0. Смена pool/admin через timelock. Глобальные роли TAR принадлежат Chainlink |
| L1 wstETH CCIP admin hook | Agent; testnet-версия из существующего core patch. Mainnet token не изменяется |
| L2 token DEFAULT_ADMIN_ROLE / ProxyAdmin owner | L2 executor. MINTER_ROLE / BURNER_ROLE — pool. Deployer после handover не имеет token admin |
| L2 executor guardian | Deployer; отмена action sets. Изменение executor settings — через его governance/self-call |

Все административные пути сохраняют production-подобное разделение контрактов. Runtime проверяет chain IDs, run ID, адреса ключей и отсутствие стандартных публичных ключей. Fork-only операции требуют loopback Anvil. Для публичного run impersonation и продвижение времени недоступны.

## Выполнение и повторная конфигурация

Перед выполнением entrypoints проверяют shell environment и локальный `.env`:
scope, bootstrap, fee recipient и migration role overrides не принимаются от
вызывающего процесса. Конфликт останавливает запуск до дочерних команд; ошибка
показывает имена переменных, без значений. RPC и ключи остаются входами оператора.
Это отдельная проверка допустимости запуска, а её регрессионные тесты — отдельное
свидетельство результата (FPF A.6.B:5.2, A.6.B:5.4). `WSTETH_SKIP_L1=1` допустим для
повторного отдельного шага, но отклоняется для полного `all`.

Порядок `all`: core/DG → **core-access** → L2 executors → stock upstream CCIP deploy/configure/handover → **verify-access** → **test-access** (только forks) → scenario tests и state verification. Изменений исходников `components/ccip` для этого нет: сгенерированный default config передаётся upstream через его `DEFAULT_CONFIG`.

Из корня репозитория, с подготовленным active run:

```sh
python3 orchestration/wsteth-ccip/workspace.py run verify-access
python3 orchestration/wsteth-ccip/workspace.py run test-access
python3 orchestration/wsteth-ccip/workspace.py run governance build agent sepolia calls.json operation.plan.json
python3 orchestration/wsteth-ccip/workspace.py run governance submit operation.plan.json
python3 orchestration/wsteth-ccip/workspace.py run governance advance operation.plan.json
python3 orchestration/wsteth-ccip/workspace.py run governance status operation.plan.json
```

`calls.json` — массив `{ "to": "0x…", "value": "0", "data": "0x…" }`. Доступные routes: `agent`, `voting`, `admin-executor`, `l2`, `ccip`. Для L2 указывается `base_sepolia` или `mantle_sepolia`. `build` не отправляет транзакций; `submit/advance` отправляют готовые стадии и сохраняют прогресс. На публичной сети нужно повторять `advance` после ожиданий и доставки сообщения. После прерванного broadcast с неизвестным хешем скрипт останавливается для сверки nonce, чтобы не создать вторую операцию.

`access-ops dsm-pause 1` подписывает pause intent первым guardian и отправляет его в DSM. Контракты guardian и их signer сохраняются в `state/dsm-guardians.json`.

`resume-lido build/submit/advance/status` использует DAO voter и тот же journal. Для lockbox: `access-ops lockbox-plan REMOTE AMOUNT_WEI RECIPIENT OUTPUT`. Для immutable allowlist: `access-ops replace-hooks CHAIN ALLOWLIST_JSON OUTPUT` **деплоит и настраивает новый hooks**, затем сохраняет CCIP proposal для принятия ownership и переключения pool; его следует выполнить отдельно через governance. Перед повторным запуском этой операции проверить уже созданный replacement record, чтобы не развернуть второй экземпляр. После переключения сверить и обновить chain record на новый hooks.

## Границы доказательства и готовности

FPF A.15 / B.3 / A.22.CGUS: наличие ключа, выданная роль, исполнимый путь и подтверждённый результат — разные утверждения. `state/access-invariants.json` фиксирует readback назначений; `state/access-rehearsal.json` и journals — результат подписанных операций на конкретных forks. Rehearsal делает snapshots и откатывает все тестовые изменения. Подписанные L2 операции используют настоящее сообщение от Agent и настоящие messenger/executor contracts; только доставка по canonical transport эмулируется alias-отправителем на Anvil. Для Mantle используются отдельные поля MNT и ETH в relayMessage, как в [Mantle Encoding](https://github.com/mantlenetworkio/mantle-v2/blob/main/packages/contracts-bedrock/src/libraries/Encoding.sol); для Base — стандартный OP ABI. Это не подтверждает работу публичного relayer.

Подготовленные oracle/DSM ключи дают доступ к контрактам. Они **не запускают** oracle daemon, validator infrastructure или производство корректных beacon reports. CSM/CMv2 не включены в этот CCIP scratch target; все контракты core и governance для его задач доступны, но полноценная эксплуатация валидаторов требует отдельного стенда.

Подтверждённый охват Nethermind — **Sepolia ↔ Base Sepolia и Sepolia ↔ Mantle Sepolia**, в обе стороны. Начальная политика уже требует **Chainlink + наш resolver → dummy**. Отдельный шаг `initial-ccv` после upstream-конфигурации применяет её до отзыва временных прав deployer, сверяет реализации Chainlink и сохраняет readback в `state/initial-ccv.<chain>.json`. Dummy не аутентифицирует событие источника: два независимых подтверждения появятся после его замены на Nethermind. При совместимом ABI меняются только inbound/outbound mappings нашего resolver; если провайдер предоставляет собственный resolver, меняется соответствующий required CCV в hooks. Chainlink остаётся обязательным. Токены и пулы передеплоить не требуется. [Процедура подключения и необходимые данные](MULTICHAIN-OPERATIONS.md#on-chain-actions-to-connect-nethermind).

Сценарий `ccv-replacement-all-networks` проверяет подписанный путь DAO → timelock → resolver на всех трёх форках: девять обновлений mappings, сохранение двух обязательных CCV в обоих направлениях каждого lane и удаление dummy-версии. Для замены используется тестовый MockCCV, адрес Chainlink сохраняется. Совместимость и криптографическая проверка будущей реализации Nethermind этим сценарием не устанавливаются.

Свежий публичный деплой и readback назначений выполнены в `public-20261104-fresh-01`. DAO voter получил 0.02 Sepolia ETH; остальные управляющие аккаунты пополняются перед использованием. Текущий результат публичных governance-сообщений и адреса для Nethermind см. в [отчёте деплоя](SEPOLIA-FRESH-DEPLOY-2026-11-04.md). Глобальные Chainlink TAR/CCIP и инфраструктура Nethermind остаются внешней ответственностью.

### Состояние публичного стенда и включение направлений

Read-only проверка 2026-11-04: RPC всех трёх сетей отвечают, bytecode Router/TAR/RegistryModule/RMN присутствует, все четыре направления поддерживаются. На каждом направлении прочитаны OnRamp / OffRamp 2.0.0, inbound включён; `laneMandatedCCVs` пуст, `defaultCCVs` содержит `0x8f3ee3c77D2B27c32306a89D367654F959Db223D`. Для token-only перевода явный ненулевой pool CCV не добавляет defaults автоматически. Поэтому начальная политика явно включает проверенный Chainlink resolver вместе с нашим resolver → dummy; выбор через `address(0)` не используется. Реализации и версия Chainlink дополнительно закреплены в `ccv-policy.json` и проверяются при конфигурации и verify-state. [Публичный readback](../../../runs/wsteth-2.0/rehearsals/access-20261104-ccv-verified/public-readiness.json) фиксирует блоки, адреса ramps, balances и CCV-настройки; это не гарантия их неизменности до deploy.

| Проверка / действие | Статус |
|---|---|
| Полный fork-прогон с текущими задержками и проверкой замены CCV | Выполнен: `access-20261104-ccv-verified` |
| Gas deployer | На момент проверки: Sepolia ≈ 6.594 ETH, Base Sepolia ≈ 2.000 ETH, Mantle Sepolia ≈ 979.263 MNT |
| Gas управляющих отправителей | DAO voter пополнен на 0.02 Sepolia ETH и использован для `core-access`; остальные пополняются перед соответствующими операциями |
| Публичный deploy и readback ролей | Выполнены: 192 проверки полномочий; [адреса, deployment blocks и CREATE-транзакции для Nethermind](SEPOLIA-FRESH-DEPLOY-2026-11-04.json) |
| Подключение Nethermind на обоих направлениях | Ожидаются адреса/ABI/версия, настройки remote chains, fees/finality, сервис подтверждений и доставки. Их отсутствие не блокирует получение новых адресов токенов |
| Итоговые «2 из 2» | После настройки провайдеров: явно требовать Chainlink + Nethermind, убрать dummy-путь, проверить все четыре направления |
| Публичный happy path | [Результат governance L1→Base и L1→Mantle](SEPOLIA-FRESH-DEPLOY-2026-11-04.md); небольшие переводы туда-обратно остаются после готовности CCV и доставки |

## Результат подготовки на форках 2026-11-04

Прогон ниже выполнен с текущим профилем: Voting 300 s, objection 60 s, DG 120 + 120 s, executor 0, три сокращённых DG-интервала по 180 s, consolidation delay 0. Отдельные локальные тесты сверяют генерируемые параметры с выбранными Core/DG defaults. Это различие настройки и результата исполнения соответствует FPF A.6.B:5.2 / A.6.B:5.4.

Полный прогон `access-20261104-chainlink-dummy` завершился успешно на свежих локальных форках Sepolia, Base Sepolia и Mantle Sepolia: deploy → назначение полномочий → handover → проверки → интеграционные сценарии. [Итог pipeline](../../../runs/wsteth-2.0/rehearsals/access-20261104-chainlink-dummy/result.json) и [сводка проверок](../../../runs/wsteth-2.0/rehearsals/access-20261104-chainlink-dummy/validation.json) сохранены локально в игнорируемом Git каталоге runs.

- **192 проверки назначений и настроек** прошли: [readback](../../../runs/wsteth-2.0/workspaces/access-20261104-chainlink-dummy/state/access-invariants.json).
- **15 сценариев с подписями подготовленных ключей** прошли, включая замену verifier на всех сетях, DAO/L2 recovery, CCIP proposer, lockbox, замену hooks, oracle quorum, DSM, reseal/tiebreaker и emergency committees: [отчёт](../../../runs/wsteth-2.0/workspaces/access-20261104-chainlink-dummy/state/access-rehearsal.json). Изменения сценариев откатились; все три Anvil остановлены.
- Начальная политика Chainlink + dummy проверена на всех трёх сетях: [адреса и версии Chainlink](../../../runs/wsteth-2.0/rehearsals/access-20261104-chainlink-dummy/chainlink-resolvers.json). Отдельные тесты проверяют отказ при одном dummy-подтверждении в каждом из четырёх направлений. Сценарий замены выполняет девять обновлений resolver и сохраняет обязательный Chainlink.
- **70 интеграционных тестов** прошли: по 35 для Mantle и Base, без пропусков. State-mate: по 198 успешных проверок и 23 пропущенных проверок на направление; пропуски не считаются подтверждением соответствующих свойств.
- Локальные проверки: **290 Python-тестов и 139 subtests, 10 Node-тестов** прошли. Рабочее дерево `components/ccip` чистое.

Вывод upstream deploy проходит через наш фильтр секретов. Ключ deployer, обнаруженный в старых диагностических логах этой подготовки, удалён из этих логов; в итоговом прогоне он маскируется до записи. Поиск известных 18 приватных ключей и mnemonic в 919 файлах итогового workspace, rehearsal evidence и CCIP foundry cache не нашёл совпадений. Это проверка указанной области, не аудит всей файловой системы.

`deploymentStatus: not-started` и `checks.onchainRolesChecked: false` в actors JSON фиксируют состояние **на момент подготовки входов**. Этот файл входит в неизменяемый input snapshot run и не обновляется результатами исполнения. Актуальные публичные результаты находятся в [отчёте деплоя](SEPOLIA-FRESH-DEPLOY-2026-11-04.md); результаты форков выше сохраняются отдельно.

Машиночитаемый список: [actors JSON](SEPOLIA-FRESH-DEPLOY-ACTORS.json). Реализация: [профиль и ключи](../script/testnet/prepare.cjs), [governance](../script/testnet/governance.cjs), [operations](../script/testnet/operations.cjs), [fork rehearsal](../script/testnet/rehearsal.cjs).
