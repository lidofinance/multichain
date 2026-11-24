# Изоляция deploy-скриптов CCIP: реализация и проверки

Дата: 4 ноября 2026 года. Статус: реализовано; все обязательные проверки плана пройдены.

Миграция хаба и Ethereum-сторона подключения Base выполняются нашим кодом.
На Base и в scratch-сценарии используются исходные upstream-скрипты.

## Что изменилось

| Действие | Исполняемый код |
| --- | --- |
| Создать хаб для существующих направлений | `script/hub-migration/DeployHubForMigration.s.sol` |
| Перенести remote pools, оба лимита, lockbox-связи и ownership | `ConfigureHubForMigration.s.sol` |
| Переключить TAR и перенести ликвидность | Прежние `05_hub_cutover.sh` и `05a_hub_accept_admin.sh` |
| Подготовить Ethereum lockbox и CCV stack для Base | `PrepareHubLane.s.sol` |
| Сформировать предложение подключения Base без broadcast | `BuildHubLaneProposal.s.sol` |
| Deploy/configure/handover на Base | Upstream `1_Deploy`, `2_Configure`, `3_SetPoolAndTransferOwnership` |
| Scratch hub и spokes | Те же три upstream-скрипта |

Общий `HubMigrationBase.sol` использует неизменённый upstream `ConfigParser`
и самостоятельно читает migration metadata. Создаваемые контракты загружаются
из артефактов CCIP, собранных профилем `ccip-compile`. Собственный профиль
`hub-migration` компилирует управляющие скрипты.

`hub_runner.py` проверяет fork, сеть, manifest, предварительный checkpoint
и привязку TAR. Он сохраняет частичные результаты при ошибке. Dry run не может
записать смоделированные адреса как deployment; builder сохраняет proposal,
не меняя records или chain state. Для CREATE проверяются receipt, creation
bytecode с аргументами, runtime с учётом immutable-полей и состояние конструктора.

Независимый Python-проверяющий сверяет все шесть вызовов предложения с records
и defaults. Отдельные readbacks до/после подключения Base проверяют старые
направления, оба лимита, их хранилища и TAR.

`ccip_build.py` проверяет gitlink, tracked/untracked/ignored исходники,
параметры сборки и фактически используемые npm-пакеты. Новая сборка удаляет
старые outputs; перед исполнением проверяются хеши. Архив включает исходники
сборки, параметры компилятора, хеши и артефакты создаваемых контрактов.
Исключаются именно `*.t.sol`, пропущенные production build; `.sol`-помощники
в тестовых каталогах остаются под проверкой.

В `components/ccip` восстановлены `1_Deploy`, `2_Configure`, `ConfigParser`
и связанные fixtures/документация. Перенесённые `4_ConnectLane` и `5_PrepareLane`
удалены после сохранения резервной копии. Существовавшая до этой задачи правка
`test/LidoTimelock.t.sol` первоначально была сохранена, затем по отдельному
указанию пользователя также перенесена в наши тесты, см. дополнение ниже.
CCIP целиком соответствует закреплённой ревизии как в проверочном checkout,
так и в основной рабочей копии.

При проверке потребителей records исправлена потеря CCV policy импортированных
направлений: при импорте они сохраняются вместе с `imported_lanes`, даже если
не являются новыми spokes выбранного target.

## Воспроизводимость

Проверочный checkout: `/tmp/wsteth-upstream-isolation-20261104`.
Snapshot исполняемых исходников: `aa8c35238a0de98db96e27d3f2b1f68ff5244e91`.
CCIP: `07ae438b0028f14d1ccce9072e3f53b8b14e8a09`.
Snapshot создан отдельным коммитом только в проверочном checkout;
индекс и история основной рабочей копии не изменялись.

Checkout создан из Git; зависимости установлены заново с package locks.
`out`, `cache` и `node_modules` основной рабочей копии не переносились.
Второй полный прогон использует окончательный код после исправлений guard
и импорта records. Изменения core при запуске — сохраняемые штатные patches.

[Материалы проверки](../../../runs/wsteth-2.0/research/upstream-isolation-20261104/)
содержат исходники до переноса (`before/`), `validation-checkout.json` с хешами,
`validation-source.bundle`, версии инструментов и общие inputs.
Bundle требует базовый commit `f10eb8a6aafa343081b15787b056eb0386705633`;
его можно импортировать в отдельный clone через `git fetch <bundle> HEAD`.
Исходники конкретных прогонов, dependency diffs и дополнительные исходные файлы
также находятся в `inputs/` соответствующих workspace/архивов.

| Линия | Закреплённые блоки |
| --- | --- |
| Mainnet | Ethereum 26341280; Base 53501959 |
| Sepolia migration | Sepolia 12062250; Base Sepolia 54356990; Monad 76908746; OP Sepolia 50995363 |
| Scratch | Sepolia 12062346; Mantle Sepolia 46124879; Base Sepolia 54362819 |

Хеши блоков записаны в `inputs/<line>/forks.json`. Четыре ответа CCIP API
(mainnet/testnet × chainId/selector) записаны с хешами в `inputs/api/`.
Replay использует ограниченный curl adapter без изменения upstream;
отсутствующий или изменённый ответ не заменяется живым API. Адреса инфраструктуры
проверяются на выбранных форках. Для повторения нужен доступ к archive RPC.

Команды из корня проверочного checkout; `INPUTS` указывает на каталог
`runs/wsteth-2.0/research/upstream-isolation-20261104/inputs` основной рабочей копии:

```sh
python3 orchestration/wsteth-ccip/rehearse.py both isolation-clean-20261104-02 --inputs "$INPUTS"
python3 orchestration/wsteth-ccip/rehearse.py scratch isolation-clean-scratch-20261104-01 --inputs "$INPUTS" --through set-pool-gov
python -m pytest orchestration/wsteth-ccip/tests -q
```

Тесты Solidity запускаются из `orchestration/wsteth-ccip` после `build-ccip`:

```sh
FOUNDRY_PROFILE=hub-migration forge test --match-path 'test/hub-migration/*.t.sol' -vv
```

## Результаты

| Проверка | Результат |
| --- | --- |
| Python orchestration, чистый checkout | passed: 144 |
| Собственные Solidity-тесты, чистый checkout | passed: 5, включая сквозной artifact deploy/configure → stock parser → prepare lane → proposal |
| Mainnet, `isolation-clean-20261104-02-mainnet` | passed: checkpoint 9; финальные сценарии 14; state-mate 342 + 9 отдельных проверок таблиц |
| Sepolia, `isolation-clean-20261104-02-sepolia` | passed: bootstrap 4; checkpoint 9; финальные сценарии 20, включая CCV; state-mate 255 + 9 отдельных проверок таблиц; переводы Monad и OP Sepolia |
| Scratch, `isolation-clean-scratch-20261104-01` | passed: stock deploy/configure/handover на Sepolia, Mantle Sepolia и Base Sepolia; независимые owner/roles/TAR/token-role readbacks |
| Новые и исторические records | passed: 4 набора; import → policy/state-mate projection → snapshot → повторный import |
| Синтаксис встроенного JavaScript explainer | passed |

Три Base-теста явно пропускаются на checkpoint до подготовки Base;
в финальном наборе они обязательны. Девять `skipped` проверок state-mate
вынесены в независимую проверку таблиц, которая также должна пройти.
Пустой, сокращённый или неожиданно пропущенный набор тестов не считается успехом.

Итоговые результаты: [Mainnet](../../../runs/wsteth-2.0/rehearsals/isolation-clean-20261104-02-mainnet/result.json),
[Sepolia](../../../runs/wsteth-2.0/rehearsals/isolation-clean-20261104-02-sepolia/result.json),
[scratch](../../../runs/wsteth-2.0/rehearsals/isolation-clean-scratch-20261104-01/result.json).
Рядом находятся pins и pipeline logs. Records, receipts, readbacks и входные
исходники сохранены под теми же идентификаторами в `runs/wsteth-2.0/workspaces/`.
Полные архивы находятся в `deployments/fork/` соответствующего workspace.

Проверка records использовала новые архивы первого чистого прогона от 4 ноября
и исторические `migration-lines-20261103-10-{mainnet,sepolia}`. Она выполнялась
окончательным кодом; точное равенство JSON проверено после импорта и round trip.
См. [результат потребителей](../../../runs/wsteth-2.0/research/upstream-isolation-20261104/record-consumers/result.json).
Исторические `imported_lanes`, `remote_lanes`, `deferred_lanes` и CCV policy
совпадают с новыми: [сравнение](../../../runs/wsteth-2.0/research/upstream-isolation-20261104/historical-record-comparison.json).
Блоки исторического прогона отличаются: это сравнение записанной конфигурации,
а не доказательство эквивалентности исполнения старого и нового кода на одинаковых inputs.
Новая реализация дополнительно проверена по manifest, defaults и chain readbacks.

Первые промежуточные probes завершились ошибками подсчёта lanes через JSON
wildcard и чтения несуществующего `getRouter()`; оба дефекта исправлены.
Проба `isolation-probe-20261104-03` прошла до `hub-connect-lane`.
Первый чистый полный прогон `isolation-clean-20261104-01` прошёл обе линии.
Эти прогоны сохранены как промежуточные; итоговая приёмка относится к `02`.

## Дополнение: оставшиеся тестовые правки CCIP

Позднее 4 ноября пользователь попросил убрать из сабмодуля также изменения
тестов. Единственный оставшийся diff заменял четыре чтения `block.timestamp`
на `vm.getBlockTimestamp()` в двух сценариях `LidoTimelock.t.sol`.
Он сохранён в резервной копии, исходный upstream-файл восстановлен.

Необходимость свежего чтения времени воспроизведена на неизменённом upstream
под `profile.ccip-compile`: оба выбранных теста падают с
`RBACTimelock: operation is not ready`. В каждой трассе два последовательных
`vm.warp` получают одинаковое время `1234827090`; второй вызов не продвигает
часы. Это проблема тестового управления временем. Она остаётся в исходных
upstream-тестах; локальный patch к ним больше не применяется.

Сценарии сохранены в нашем
[`LidoTimelockQueue.t.sol`](../test/hub-migration/LidoTimelockQueue.t.sol):
выполненный predecessor остаётся допустимым после halt/restart; отменённый
halt-ом predecessor требует повторного предложения и исполнения.
Оба используют `vm.getBlockTimestamp()` и создают timelock из CCIP release
artifact, не перекомпилируя его под профиль наших тестов.

После переноса `FOUNDRY_PROFILE=hub-migration forge test --match-path
'test/hub-migration/*.t.sol' -vv` дал **7 passed, 0 failed**: прежние пять и два
перенесённых сценария. `git -C components/ccip status --porcelain` пустой.
CCIP пересобран, provenance verification пройдена; creation/runtime bytecode
всех 11 архивируемых контрактов совпадает с артефактами итоговой fork-приёмки.
Deploy-код и его inputs не изменились; полные fork-линии повторно не запускались.

Исходный diff, трассы двух воспроизведённых upstream failures, успешный наш
прогон и сравнение bytecode сохранены в
[материалах дополнения](../../../runs/wsteth-2.0/research/ccip-timelock-test-isolation-20261104/).
Snapshot `aa8c352…` и таблица основной приёмки выше относятся к предыдущему
этапу; новые два теста добавлены после него.

## Границы вывода и применение FPF

Приёмка относится к fork-оркестрации. Публичные транзакции, реальные подписи
Chainlink MCMS, доставка через DON и работа сервиса Nethermind не проверялись.
Действия операторов и подтверждения воспроизводятся тестовыми средствами.
Mainnet checkpoint проверяет Ethereum-границу существующих направлений;
удалённые Mainnet-сети не поднимаются. Sepolia отдельно проверяет Monad и OP Sepolia.
Scratch проверяется до передачи управления включительно; это область приёмки
stock deploy/configure/handover, а не полный scratch suite переводов.

Применены FPF Core C.39, B.1.5.RS и C.11.DUA: проверен обмен артефактами между
этапами, а замена скриптов проверена во всех затронутых использованиях — Mainnet,
Sepolia, scratch и потребители records. Успешная сборка, созданное предложение
и выполненная миграция учитываются как разные результаты. Полные линии
повторены после последних исправлений; старые результаты не выданы за проверку
окончательной версии. Остальные findings исходного ревью этим переносом
автоматически не закрываются.
