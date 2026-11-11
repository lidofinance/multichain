# Архитектура wstETH на CCIP: компоненты и кто чем управляет

Дата: 2026-11-11. Источники перечислены в [разделе 11](#11-источники-и-когда-обновлять).

| Диаграмма | Вопрос, на который она отвечает |
| --- | --- |
| [1. Обзор](#1-обзор-кто-чем-управляет) | Кто чем управляет, где L1 и L2, что принадлежит Lido и что Chainlink |
| [2. Все элементы](#2-все-элементы) | Какие контракты и акторы есть в каждой сети и как они связаны |
| [7. Операция управления](#7-как-проходит-операция-управления) | Как меняется конфигурация и кто может остановить изменение |
| [8. Подключение новой сети](#8-как-подключается-новая-сеть) | Что развёртывается и кто что делает, чтобы открыть новый lane |
| [9. Путь перевода](#9-путь-перевода-ethereum--base) | Через какие контракты проходит перевод wstETH, где участвует CCV и где проверяется «2 из 2» |

## Что здесь описано

Целевое устройство пары **Ethereum ↔ Base** после DAO-голосования по миграции Base и до
`close()` на обоих legacy bridge: то состояние, которое проверяет state-mate в
[`targets/wsteth-base-migration-mainnet`](targets/wsteth-base-migration-mainnet/README.md).
Остальные сети отличаются от этой пары деталями, они собраны в [разделе 10](#10-чего-на-схемах-нет).

Статус этого устройства:

- **mainnet**: зелёные контракты не развернуты, и legacy bridge с token на Base ещё не обновлены. Существуют Agent,
  `OptimismBridgeExecutor`, wstETH, оба legacy bridge и инфраструктура Chainlink. Переход отрепетирован на forks
  Ethereum и Base; адреса Emergency Brakes и Chainlink MCMS на новых контрактах в репетиции подставные.
- **Sepolia**: развернуто 2026-11-04 по той же модели управления
  ([отчёт](orchestration/wsteth-ccip/docs/SEPOLIA-FRESH-DEPLOY-2026-11-04.md)), с отличиями из раздела 10.

Схемы показывают задуманную структуру. Они не доказывают состояние сети: фактические адреса и
значения берутся из chain records, state-mate и [`ledger.json`](ledger.json).

## 1. Обзор: кто чем управляет

```mermaid
%%{init: {"flowchart": {"nodeSpacing": 28, "rankSpacing": 38}}}%%
flowchart TB
  subgraph L1["ETHEREUM (L1)"]
    direction TB
    subgraph L1L["Lido"]
      AGENT(["Lido DAO<br/>Agent"])
      EB1(["Emergency<br/>Brakes"])
      L1BR[["PROXY<br/>L1 bridge"]]
      WSTETH["wstETH<br/>не upgradeable"]
    end
    subgraph L1S["CCIP lane wstETH"]
      TL1["LidoTimelock<br/>delay 3 дня"]
      POOL1["TokenPool<br/>+ hooks + CCV"]
      LB1["ERC20LockBox x5<br/>хранят wstETH"]
    end
    subgraph L1C["Chainlink"]
      CL1(["Chainlink<br/>MCMS"])
      CCIP1["Router, OnRamp,<br/>OffRamp, RMN"]
      TAR1["TokenAdmin<br/>Registry"]
    end
  end

  RELAY["OP Stack<br/>messengers"]

  subgraph L2["BASE (L2)"]
    direction TB
    subgraph L2L["Lido"]
      OPEXEC(["Optimism<br/>BridgeExecutor"])
      EB2(["Emergency<br/>Brakes"])
      L2BR[["PROXY<br/>L2 bridge"]]
      TOKEN2[["PROXY<br/>wstETH"]]
    end
    subgraph L2S["CCIP lane wstETH"]
      TL2["LidoTimelock<br/>delay 3 дня"]
      POOL2["TokenPool<br/>+ hooks + CCV"]
    end
    subgraph L2C["Chainlink"]
      CL2(["Chainlink<br/>MCMS"])
      TAR2["TokenAdmin<br/>Registry"]
      CCIP2["Router, OnRamp,<br/>OffRamp, RMN"]
    end
  end

  TL1 -->|"admin записи<br/>wstETH"| TAR1
  AGENT ==>|"ADMIN_ROLE<br/>+ bypass"| TL1
  AGENT ==>|"proxy admin"| L1BR
  TL1 ==>|"owner"| POOL1
  TL1 ==>|"owner"| LB1
  CL1 ==>|"управляет"| CCIP1
  CL1 ==>|"управляет"| TAR1
  L1BR ~~~ WSTETH

  CL1 -->|"PROPOSER<br/>CANCELLER"| TL1
  EB1 -->|"CANCELLER<br/>QUEUE_HALT"| TL1
  EB1 -->|"PAUSE"| POOL1
  EB1 -->|"disable<br/>Deposits"| L1BR
  POOL1 -->|"caller"| LB1
  L1BR -->|"caller,<br/>до close()"| LB1

  TL2 -->|"admin записи<br/>wstETH"| TAR2
  OPEXEC ==>|"ADMIN_ROLE<br/>+ bypass"| TL2
  OPEXEC ==>|"proxy admin"| L2BR
  OPEXEC ==>|"proxy admin"| TOKEN2
  TL2 ==>|"owner"| POOL2
  CL2 ==>|"управляет"| CCIP2
  CL2 ==>|"управляет"| TAR2

  CL2 -->|"PROPOSER<br/>CANCELLER"| TL2
  EB2 -->|"CANCELLER<br/>QUEUE_HALT"| TL2
  EB2 -->|"PAUSE"| POOL2
  EB2 -->|"disable<br/>Withdrawals"| L2BR
  POOL2 -->|"MINTER<br/>BURNER"| TOKEN2
  L2BR -->|"MINTER, BURNER,<br/>до close()"| TOKEN2

  AGENT -.->|"sendMessage"| RELAY
  RELAY -.->|"queue,<br/>execute"| OPEXEC
  LB1 ~~~ RELAY
  CCIP1 <-.->|"сообщения CCIP"| CCIP2

  classDef lido fill:#DBEAFE,stroke:#1D4ED8,stroke-width:1px,color:#0F172A
  classDef lidoProxy fill:#DBEAFE,stroke:#1D4ED8,stroke-width:3px,stroke-dasharray:6 4,color:#0F172A
  classDef lane fill:#DCFCE7,stroke:#15803D,stroke-width:1px,color:#052E16
  classDef chainlink fill:#FFEDD5,stroke:#C2410C,stroke-width:1px,color:#431407
  classDef opstack fill:#E5E7EB,stroke:#6B7280,stroke-width:1px,color:#111827

  class AGENT,EB1,WSTETH,OPEXEC,EB2 lido
  class L1BR,TOKEN2,L2BR lidoProxy
  class TL1,POOL1,LB1,TL2,POOL2 lane
  class CL1,TAR1,CCIP1,CL2,TAR2,CCIP2 chainlink
  class RELAY opstack

  style L1 fill:none,stroke:#64748B,stroke-width:2px
  style L2 fill:none,stroke:#64748B,stroke-width:2px
  style L1L fill:#3B82F61A,stroke:#3B82F6
  style L2L fill:#3B82F61A,stroke:#3B82F6
  style L1S fill:#22C55E1A,stroke:#22C55E
  style L2S fill:#22C55E1A,stroke:#22C55E
  style L1C fill:#F973161A,stroke:#F97316
  style L2C fill:#F973161A,stroke:#F97316
```

### Как читать схемы

Стрелка всегда направлена от того, кто имеет право, к тому, над чем это право действует.
Расположение блоков выше или ниже ничего не означает. Обозначения одинаковы на всех схемах.

| Обозначение | Значение |
| --- | --- |
| Синий блок | Сторона Lido: DAO, её multisig и контракты, которые меняет только DAO |
| Зелёный блок | Контракт CCIP lane для wstETH: владеет Lido через `LidoTimelock`, обычные изменения предлагает Chainlink MCMS |
| Оранжевый блок | Система Chainlink: Lido её не меняет |
| Серый блок | Ни Lido, ни Chainlink: OP Stack, deployer, любой адрес |
| Скруглённый блок | Актор, который держит роли: DAO, multisig, governance executor |
| Прямоугольник | Контракт. У синих и зелёных прямоугольников upgrade невозможен; для оранжевых и серых upgradeability не показана |
| Блок `PROXY` с толстой пунктирной рамкой | Proxy: implementation можно заменить |
| Блок `NEW` с толстой рамкой | Появляется при подключении новой сети (только раздел 8) |
| Толстая стрелка | Полная власть: `owner()`, `ADMIN_ROLE`, proxy admin, управление системой Chainlink |
| Тонкая стрелка | Ограниченная роль: названа на стрелке |
| Пунктирная стрелка | Связь без власти: вызов, ссылка в конфигурации, implementation, доставка между сетями |

На обзорной схеме несколько блоков объединяют по нескольку контрактов или адресов. По отдельности они показаны в разделе 2.

| Блок на обзорной схеме | Что в нём |
| --- | --- |
| `TokenPool + hooks + CCV`, Ethereum | `SiloedLockReleaseTokenPool`; `PausableAdvancedPoolHooks`; `VersionedVerifierResolver` и `DummyMessageIdVerifier`. Четыре контракта, owner каждого — `LidoTimelock`. Роль `PAUSE` действует на hooks |
| `TokenPool + hooks + CCV`, Base | `BurnMintTokenPool`; `PausableAdvancedPoolHooks`; `VersionedVerifierResolver` и `DummyMessageIdVerifier`. `MINTER_ROLE` и `BURNER_ROLE` на token держит pool |
| `LidoTimelock` | `LidoTimelock` и его `CallProxy`: готовый proposal исполняет любой адрес. Delay 3 дня, proposal истекает через 14 дней |
| `ERC20LockBox x5` | Общий lockbox для Monad и MegaETH и отдельные lockbox для Bitlayer, 0G, Robinhood и Base |
| `Chainlink MCMS` | Multisig Chainlink с ролями на `LidoTimelock` и governance Chainlink, которое управляет её инфраструктурой. Один ли это адрес, в репозитории не зафиксировано |
| `Router, OnRamp, OffRamp, RMN` | Общая инфраструктура CCIP в этой сети, включая RMN proxy |
| `OP Stack messengers` | `L1CrossDomainMessenger` на Ethereum и `L2CrossDomainMessenger` на Base |
| `proxy admin` | У Agent и `OptimismBridgeExecutor` на тех же контрактах есть и `DEFAULT_ADMIN_ROLE` |
| `admin записи wstETH` | `LidoTimelock` — administrator записи wstETH в `TokenAdminRegistry`: назначает pool |

## 2. Все элементы

Здесь каждый контракт и актор показан отдельным блоком. Схемы широкие: на GitHub удобнее открыть их через
кнопки масштаба в углу диаграммы.

### 2.1. Ethereum (L1)

```mermaid
%%{init: {"flowchart": {"nodeSpacing": 28, "rankSpacing": 42}}}%%
flowchart TB
  subgraph CL["Chainlink"]
    MCMS(["Chainlink MCMS"])
    CLTL(["RBACTimelock Chainlink<br/>delay 3 часа"])
    DON(["Off-chain сеть<br/>Chainlink"])
    subgraph INFRA["Инфраструктура CCIP"]
      ROUTER["Router"]
      ONRAMP["OnRamp"]
      OFFRAMP["OffRamp"]
      RMN[["PROXY<br/>RMN proxy"]]
      TAR["TokenAdminRegistry"]
      RMOC["RegistryModule<br/>OwnerCustom"]
    end
    OLDPOOL["Старый pool 1.6.0<br/>до cutover"]
  end

  subgraph LANE["CCIP lane wstETH"]
    TL["LidoTimelock"]
    CP["CallProxy"]
    POOL["SiloedLockRelease<br/>TokenPool"]
    HOOKS["PausableAdvanced<br/>PoolHooks"]
    RES["VersionedVerifier<br/>Resolver"]
    VER["DummyMessageId<br/>Verifier"]
    LB4["ERC20LockBox x4<br/>shared, Bitlayer,<br/>0G, Robinhood<br/>хранят wstETH"]
    LBB["ERC20LockBox Base<br/>хранит wstETH"]
  end

  subgraph LIDO["Lido"]
    DAO(["Lido DAO<br/>голосование"])
    AGENT(["Lido DAO<br/>Agent"])
    EB(["Emergency<br/>Brakes"])
    L1BR[["PROXY<br/>L1 bridge"]]
    L1IMPL["L1MigrationBridge<br/>implementation"]
    WSTETH["wstETH<br/>не upgradeable"]
  end

  subgraph OP["OP Stack"]
    L1MSG["L1CrossDomain<br/>Messenger"]
    PORTAL["OptimismPortal"]
  end

  ANY(["Любой адрес"])

  DAO ==>|"решение"| AGENT
  AGENT ==>|"ADMIN_ROLE<br/>+ bypass"| TL
  AGENT ==>|"proxy admin"| L1BR
  TL ==>|"owner"| POOL
  TL ==>|"owner"| HOOKS
  TL ==>|"owner"| RES
  TL ==>|"owner"| VER
  TL ==>|"owner"| LB4
  TL ==>|"owner"| LBB
  CLTL ==>|"управляет"| ROUTER
  CLTL ==>|"управляет"| TAR
  CLTL ==>|"owner"| OLDPOOL

  MCMS -->|"PROPOSER<br/>CANCELLER"| TL
  EB -->|"CANCELLER<br/>QUEUE_HALT"| TL
  CP -->|"EXECUTOR"| TL
  ANY -->|"executeBatch"| CP
  EB -->|"PAUSE"| HOOKS
  EB -->|"disable<br/>Deposits"| L1BR
  TL -->|"admin записи<br/>wstETH"| TAR
  POOL -->|"caller"| LB4
  POOL -->|"caller"| LBB
  L1BR -->|"caller,<br/>до close()"| LBB

  TAR -.->|"wstETH: pool"| POOL
  POOL -.->|"hooks"| HOOKS
  HOOKS -.->|"required CCV<br/>для Base"| RES
  RES -.->|"verifier"| VER
  ROUTER -.-> ONRAMP
  ROUTER -.-> OFFRAMP
  ONRAMP -.->|"lockOrBurn"| POOL
  OFFRAMP -.->|"releaseOrMint"| POOL
  POOL -.->|"проверка RMN"| RMN
  DON -.->|"execute"| OFFRAMP
  L1BR -.->|"код"| L1IMPL
  L1IMPL ~~~ WSTETH
  L1BR -.->|"ccipSend"| ROUTER
  L1BR -.->|"legacy"| L1MSG
  AGENT -.->|"решения<br/>для Base"| L1MSG
  PORTAL -.->|"legacy withdrawals"| L1MSG

  class DAO,AGENT,EB,WSTETH,L1IMPL lido
  class L1BR lidoProxy
  class TL,CP,POOL,HOOKS,RES,VER,LB4,LBB lane
  class MCMS,CLTL,DON,ROUTER,ONRAMP,OFFRAMP,TAR,RMOC,OLDPOOL chainlink
  class RMN chainlinkProxy
  class L1MSG,PORTAL,ANY neutral

  style CL fill:#F973161A,stroke:#F97316
  style INFRA fill:#F973161A,stroke:#F97316,stroke-dasharray:3 3
  style LANE fill:#22C55E1A,stroke:#22C55E
  style LIDO fill:#3B82F61A,stroke:#3B82F6
  style OP fill:#9CA3AF1A,stroke:#9CA3AF

  classDef lido fill:#DBEAFE,stroke:#1D4ED8,stroke-width:1px,color:#0F172A
  classDef lidoProxy fill:#DBEAFE,stroke:#1D4ED8,stroke-width:3px,stroke-dasharray:6 4,color:#0F172A
  classDef lane fill:#DCFCE7,stroke:#15803D,stroke-width:1px,color:#052E16
  classDef chainlink fill:#FFEDD5,stroke:#C2410C,stroke-width:1px,color:#431407
  classDef chainlinkProxy fill:#FFEDD5,stroke:#C2410C,stroke-width:3px,stroke-dasharray:6 4,color:#431407
  classDef neutral fill:#E5E7EB,stroke:#6B7280,stroke-width:1px,color:#111827
  classDef laneNew fill:#DCFCE7,stroke:#15803D,stroke-width:4px,color:#052E16
  classDef lidoNewProxy fill:#DBEAFE,stroke:#1D4ED8,stroke-width:4px,stroke-dasharray:6 4,color:#0F172A
```

### 2.2. Base (L2)

```mermaid
%%{init: {"flowchart": {"nodeSpacing": 28, "rankSpacing": 42}}}%%
flowchart TB
  subgraph CL["Chainlink"]
    MCMS(["Chainlink MCMS"])
    CLGOV(["Governance<br/>Chainlink"])
    DON(["Off-chain сеть<br/>Chainlink"])
    subgraph INFRA["Инфраструктура CCIP"]
      ROUTER["Router"]
      ONRAMP["OnRamp"]
      OFFRAMP["OffRamp"]
      RMN[["PROXY<br/>RMN proxy"]]
      TAR["TokenAdminRegistry"]
      RMOC["RegistryModule<br/>OwnerCustom"]
    end
  end

  subgraph LANE["CCIP lane wstETH"]
    TL["LidoTimelock"]
    CP["CallProxy"]
    POOL["BurnMint<br/>TokenPool"]
    HOOKS["PausableAdvanced<br/>PoolHooks"]
    RES["VersionedVerifier<br/>Resolver"]
    VER["DummyMessageId<br/>Verifier"]
  end

  subgraph LIDO["Lido"]
    EB(["Emergency<br/>Brakes"])
    OPEXEC(["Optimism<br/>BridgeExecutor"])
    L2BR[["PROXY<br/>L2 bridge"]]
    L2IMPL["L2MigrationBridge<br/>implementation"]
    TOKEN[["PROXY<br/>wstETH"]]
    TIMPL["ERC20BridgedPermit<br/>implementation"]
  end

  subgraph OP["OP Stack"]
    L2MSG["L2CrossDomain<br/>Messenger"]
  end

  ANY(["Любой адрес"])

  EB -->|"CANCELLER<br/>QUEUE_HALT"| TL
  OPEXEC ==>|"ADMIN_ROLE<br/>+ bypass"| TL
  OPEXEC ~~~ EB
  OPEXEC ==>|"proxy admin"| L2BR
  OPEXEC ==>|"proxy admin"| TOKEN
  TL ==>|"owner"| POOL
  TL ==>|"owner"| HOOKS
  TL ==>|"owner"| RES
  TL ==>|"owner"| VER
  CLGOV ==>|"управляет"| ROUTER
  CLGOV ==>|"управляет"| TAR

  MCMS -->|"PROPOSER<br/>CANCELLER"| TL
  CP -->|"EXECUTOR"| TL
  ANY -->|"executeBatch"| CP
  EB -->|"PAUSE"| HOOKS
  EB -->|"disable<br/>Withdrawals"| L2BR
  TL -->|"admin записи<br/>wstETH"| TAR
  POOL -->|"MINTER<br/>BURNER"| TOKEN
  L2BR -->|"MINTER, BURNER,<br/>до close()"| TOKEN

  L2MSG -.->|"решения<br/>от Agent"| OPEXEC
  L2MSG <-.->|"legacy"| L2BR
  TAR -.->|"wstETH: pool"| POOL
  POOL -.->|"hooks"| HOOKS
  HOOKS -.->|"required CCV"| RES
  RES -.->|"verifier"| VER
  HOOKS -.->|"разрешены ли<br/>исходящие"| L2BR
  ROUTER -.-> ONRAMP
  ROUTER -.-> OFFRAMP
  ONRAMP -.->|"lockOrBurn"| POOL
  OFFRAMP -.->|"releaseOrMint"| POOL
  POOL -.->|"проверка RMN"| RMN
  DON -.->|"execute"| OFFRAMP
  L2BR -.->|"код"| L2IMPL
  TOKEN -.->|"код"| TIMPL
  L2BR -.->|"ccipSend"| ROUTER

  class OPEXEC,EB,L2IMPL,TIMPL lido
  class L2BR,TOKEN lidoProxy
  class TL,CP,POOL,HOOKS,RES,VER lane
  class MCMS,CLGOV,DON,ROUTER,ONRAMP,OFFRAMP,TAR,RMOC chainlink
  class RMN chainlinkProxy
  class L2MSG,ANY neutral

  style CL fill:#F973161A,stroke:#F97316
  style INFRA fill:#F973161A,stroke:#F97316,stroke-dasharray:3 3
  style LANE fill:#22C55E1A,stroke:#22C55E
  style LIDO fill:#3B82F61A,stroke:#3B82F6
  style OP fill:#9CA3AF1A,stroke:#9CA3AF

  classDef lido fill:#DBEAFE,stroke:#1D4ED8,stroke-width:1px,color:#0F172A
  classDef lidoProxy fill:#DBEAFE,stroke:#1D4ED8,stroke-width:3px,stroke-dasharray:6 4,color:#0F172A
  classDef lane fill:#DCFCE7,stroke:#15803D,stroke-width:1px,color:#052E16
  classDef chainlink fill:#FFEDD5,stroke:#C2410C,stroke-width:1px,color:#431407
  classDef chainlinkProxy fill:#FFEDD5,stroke:#C2410C,stroke-width:3px,stroke-dasharray:6 4,color:#431407
  classDef neutral fill:#E5E7EB,stroke:#6B7280,stroke-width:1px,color:#111827
  classDef laneNew fill:#DCFCE7,stroke:#15803D,stroke-width:4px,color:#052E16
  classDef lidoNewProxy fill:#DBEAFE,stroke:#1D4ED8,stroke-width:4px,stroke-dasharray:6 4,color:#0F172A
```

### 2.3. Адреса существующих контрактов mainnet

Адреса прочитаны из mainnet в даты, записанные в `target.json` (2026-10-21, 2026-10-26, 2026-10-30), и из API Chainlink.
Зелёные контракты в mainnet не развернуты, поэтому адресов у них нет.

| Элемент | Ethereum | Base |
| --- | --- | --- |
| DAO-адрес сети | Agent `0x3e40D73EB977Dc6a537aF587D48316feE66E9C8c` | `OptimismBridgeExecutor` `0x0E37599436974a25dDeEdF795C848d30Af46eaCF` |
| wstETH | `0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0` | `0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452` |
| Legacy bridge (proxy) | `0x9de443AdC5A411E83F1878Ef24C3F52C61571e72` | `0xac9D11cD4D7eF6e54F14643a393F68Ca014287AB` |
| Emergency Brakes на legacy bridge | `0x73b047fe6337183A454c5217241D780a932777bD` | `0x0F9A0e7071B7B21bc7a8514DA2cd251bc1FF0725` |
| CrossDomainMessenger | `0x866E82a600A1414e583f7F13623F1aC5d58b0Afa` | `0x4200000000000000000000000000000000000007` |
| Router | `0x80226fc0Ee2b096224EeAc085Bb9a8cba1146f7D` | `0x881e3A65B4d4a04dD529061dd0071cf975F58bCD` |
| TokenAdminRegistry | `0xb22764f98dD05c789929716D677382Df22C05Cb6` | `0x6f6C373d09C07425BaAE72317863d7F6bb731e37` |
| RegistryModuleOwnerCustom | `0x4855174E9479E211337832E109E7721d43A4CA64` | `0xAFEd606Bd2CAb6983fC6F10167c98aaC2173D77f` |
| RMN proxy | `0x411dE17f12D1A34ecC7F45f49844626267c75e81` | `0xC842c69d54F83170C42C4d556B4F6B2ca53Dd3E8` |
| OnRamp 2.0.0 | `0xc3423F3FB30857D9C14717b119884b1B63d250b7` | не записан |
| OffRamp 2.0.0 | `0x408428bca0e24A25ac8baAc1b70f64AF257717c3` | не записан |
| RBACTimelock Chainlink | `0x44835bBBA9D40DEDa9b64858095EcFB2693c9449` | не записан |
| Старый pool wstETH 1.6.0 | `0xA586a732394A1AFfCF15b972cd47C936033C9FA7` | — |

На Ethereum кроме OffRamp 2.0.0 входящие сообщения принимают общий OffRamp 1.6.0 и старые OffRamp отдельных сетей;
они перечислены в [плане миграции hub](targets/wsteth-base-migration-mainnet/CHAINLINK_HUB_MIGRATION_FORK_PLAN.md).

## 3. Что значит «владеет»

За толстыми стрелками на схемах стоят пять разных прав. Они выдаются отдельно и держатся разными адресами.

| Право | Что позволяет | Кто держит |
| --- | --- | --- |
| `owner()` | Менять конфигурацию контракта | `LidoTimelock` на pool, hooks, lockbox, resolver, verifier |
| `ADMIN_ROLE` на `LidoTimelock` | Выдавать и отзывать роли timelock, менять delay и blocked selectors, исполнять batch немедленно через `bypasserExecuteBatch` | Agent на Ethereum; `OptimismBridgeExecutor` на Base |
| proxy admin | Заменить implementation | Agent на Ethereum; `OptimismBridgeExecutor` на Base |
| `DEFAULT_ADMIN_ROLE` | Выдавать и отзывать роли на token и legacy bridge | Agent на Ethereum; `OptimismBridgeExecutor` на Base |
| administrator записи в `TokenAdminRegistry` | Назначать pool для wstETH через `setPool` | `LidoTimelock` |

`TokenAdminRegistry` — контракт Chainlink. Lido управляет в нём только записью своего token.

## 4. Четыре зоны контроля

| Зона | Контракты | Кто меняет | Как |
| --- | --- | --- | --- |
| Только Lido | wstETH на Base; оба legacy bridge; их proxy | Lido DAO | Голосование → Agent; на Base дополнительно сообщение через OP Stack → `OptimismBridgeExecutor` |
| Lido владеет, Chainlink предлагает | `LidoTimelock`; pool; hooks; lockbox; resolver и verifier | Chainlink MCMS предлагает, Lido может остановить или сделать сам | `scheduleBatch` → 3 дня → исполнение любым адресом через `CallProxy`. Emergency Brakes: `cancel`, `haltProposalQueue`. DAO: `bypasserExecuteBatch` без задержки |
| Chainlink | Router; OnRamp; OffRamp; RMN proxy; `TokenAdminRegistry`; off-chain сеть доставки | Chainlink | Собственное governance Chainlink |
| OP Stack | `L1CrossDomainMessenger`; `L2CrossDomainMessenger` | Не Lido и не Chainlink | В репозитории не описано |

Что Chainlink MCMS **не может** провести через `LidoTimelock`: пять selectors заблокированы для proposals,
их исполняет только DAO через bypass.

- `transferOwnership(address)`
- `transferAdminRole(address,address)`
- `upgradeToAndCall(address,bytes)`
- `grantRole(bytes32,address)`
- `revokeRole(bytes32,address)`

Proposal исполняется от имени timelock, а timelock не держит ролей на самом себе, поэтому proposal не может
поменять роли timelock, delay или список blocked selectors.

Что Lido может сделать с частью Chainlink, не меняя её:

- остановить переводы: Emergency Brakes вызывает pause на hooks, сразу, без timelock;
- ограничить объём: rate limits на pool (по умолчанию 330 wstETH исходящих, 500 wstETH входящих за ~24 часа на lane);
- потребовать дополнительную проверку сообщений: список required CCV в hooks;
- отвязать pool от token: `setPool` в `TokenAdminRegistry` через timelock.

Снять pause может только owner hooks, то есть proposal через timelock или DAO через bypass.

## 5. Proxy и upgradeable

| Контракт | Сеть | Upgradeable | Кто меняет implementation |
| --- | --- | --- | --- |
| L1 bridge (`L1MigrationBridge`) | Ethereum | Да, `OssifiableProxy` | Agent |
| L2 bridge (`L2MigrationBridge`) | Base | Да, `OssifiableProxy` | `OptimismBridgeExecutor` |
| wstETH на Base (`ERC20BridgedPermit`) | Base | Да, `OssifiableProxy` | `OptimismBridgeExecutor` |
| wstETH на новом spoke (`ERC20BridgedPermit`) | новый L2 | Да, `TransparentUpgradeableProxy` + `ProxyAdmin` | DAO-адрес этой сети как owner `ProxyAdmin` |
| wstETH | Ethereum | Нет | — |
| `LidoTimelock`, `CallProxy` | обе | Нет | — |
| `SiloedLockReleaseTokenPool`, `BurnMintTokenPool` | Ethereum, Base | Нет | — |
| `PausableAdvancedPoolHooks`, `ERC20LockBox` | обе | Нет | — |
| `VersionedVerifierResolver`, `DummyMessageIdVerifier` | обе | Нет | — |
| RMN proxy | обе | Proxy Chainlink | Chainlink; в репозитории не проверяется |

Контракты CCIP lane заменяются новым деплоем и перенастройкой, а не upgrade. Точки замены:

- pool — `TokenAdminRegistry.setPool`;
- lockbox — `configureLockBoxes` на pool;
- required CCV — `applyCCVConfigUpdates` на hooks;
- verifier за resolver — `applyOutboundImplementationUpdates` и `applyInboundImplementationUpdates` на resolver.

`CallProxy` — не upgrade proxy: это исполнитель proposals, который пересылает любой вызов в свой timelock.

## 6. Акторы и роли

| Актор | Сеть | Что это | Роли |
| --- | --- | --- | --- |
| Lido DAO Agent `0x3e40D73EB977Dc6a537aF587D48316feE66E9C8c` | Ethereum | Адрес, от имени которого исполняются решения DAO | `ADMIN_ROLE` на `LidoTimelock`; proxy admin и `DEFAULT_ADMIN_ROLE` на L1 bridge; отправитель решений для Base |
| `OptimismBridgeExecutor` `0x0E37599436974a25dDeEdF795C848d30Af46eaCF` | Base | Исполнитель решений DAO на Base: принимает action sets только от Agent, delay 0, grace period 1 день, guardian отсутствует | `ADMIN_ROLE` на `LidoTimelock`; proxy admin и `DEFAULT_ADMIN_ROLE` на token и L2 bridge |
| Emergency Brakes | обе | Multisig Lido для быстрых остановок | На `LidoTimelock`: `CANCELLER_ROLE`, `PROPOSAL_QUEUE_HALT_ROLE`. На hooks: `CROSS_CHAIN_TRANSFERS_PAUSE_ROLE`. На legacy bridge: `disableDeposits` (Ethereum), `disableWithdrawals` (Base) |
| Chainlink MCMS | обе | Multisig Chainlink | На `LidoTimelock`: `PROPOSER_ROLE`, `CANCELLER_ROLE`. На hooks ролей нет |
| Chainlink governance | обе | MCMS и `RBACTimelock` Chainlink | Управляет инфраструктурой CCIP. На контрактах Lido ролей нет |
| Любой адрес | обе | — | Исполняет готовый proposal через `CallProxy`; вызывает `activate()` и `close()` на legacy bridge после срока |
| Deployer | обе | Ключ развёртывания | После передачи ролей не держит ничего |

Адреса Emergency Brakes на действующих legacy bridge прочитаны из mainnet 2026-10-26.
Кто будет держать роли Emergency Brakes и Chainlink MCMS на новых `LidoTimelock` и hooks в mainnet,
не зафиксировано: в target стоят подставные адреса.

Сегодня в mainnet `RBACTimelock` Chainlink — owner действующего pool 1.6.0 и administrator записи wstETH
в `TokenAdminRegistry` на Ethereum. После cutover запись wstETH указывает на новый pool, а её administrator — `LidoTimelock`.

## 7. Как проходит операция управления

Операция здесь — изменение конфигурации контрактов CCIP lane: rate limits, новый lane, набор required CCV,
замена verifier. Все такие изменения идут через `LidoTimelock` одной из трёх дорог.

```mermaid
sequenceDiagram
  autonumber
  box rgba(249,115,22,0.12) Chainlink
    participant M as Chainlink MCMS
  end
  box rgba(34,197,94,0.12) CCIP lane wstETH
    participant T as LidoTimelock
    participant C as CallProxy
    participant X as Pool, hooks,<br/>lockbox, CCV
  end
  box rgba(59,130,246,0.12) Lido
    participant E as Emergency Brakes
    participant D as Lido DAO
  end
  participant A as Любой адрес

  Note over M,A: Обычная операция: предлагает Chainlink
  M->>T: scheduleBatch(вызовы)
  Note over T: Отказ, если в batch есть blocked selector
  Note over T: Ожидание 3 дня
  opt Lido не согласна
    E->>T: cancel(id) или haltProposalQueue()
    Note over T: Proposal больше не исполнить
  end
  A->>C: executeBatch(вызовы)
  C->>T: executeBatch(вызовы)
  T->>X: вызовы от имени owner
  Note over T: Не исполнен за 14 дней: proposal истекает

  Note over M,A: Операция DAO: без задержки, в том числе blocked selectors
  D->>T: bypasserExecuteBatch(вызовы)
  T->>X: вызовы от имени owner

  Note over M,A: Экстренная остановка переводов: без timelock
  E->>X: pause на hooks
```

| Дорога | Кто начинает | Задержка | Что можно провести | Кто может остановить |
| --- | --- | --- | --- | --- |
| Обычная | Chainlink MCMS: `scheduleBatch` | 3 дня; proposal истекает через 14 дней после постановки | Любые вызовы от имени owner, кроме пяти blocked selectors | Emergency Brakes или Chainlink MCMS: `cancel(id)`. Emergency Brakes: `haltProposalQueue()` |
| DAO | Lido DAO: `bypasserExecuteBatch` | Нет | Всё, включая blocked selectors: смена owner, роли, передача administrator записи | Никто на уровне timelock |
| Экстренная остановка | Emergency Brakes: pause на hooks | Нет | Только остановка переводов | — |

- `haltProposalQueue()` делает недействительными все ожидающие proposals и запрещает новые, пока DAO не вызовет
  `restartProposalQueue()`. Путь DAO через bypass работает и при остановленной очереди.
- На Ethereum DAO действует через Agent. На Base решение DAO идёт дальше: Agent → `L1CrossDomainMessenger` →
  `L2CrossDomainMessenger` → `OptimismBridgeExecutor`, и уже он вызывает `bypasserExecuteBatch`.
- У каждой сети свой `LidoTimelock`. Изменение, которое затрагивает обе стороны lane, — это два proposals, по одному в каждой сети.
- Снять pause — это вызов от имени owner hooks: обычной дорогой или дорогой DAO.

Token и legacy bridge через `LidoTimelock` не меняются: их меняет только DAO напрямую, как описано в разделе 4.

## 8. Как подключается новая сеть

На схеме только те элементы, которые участвуют в подключении. Блоки `NEW` появляются в ходе подключения,
остальные уже существуют. Номера на стрелках — шаги из таблицы ниже.

```mermaid
%%{init: {"flowchart": {"nodeSpacing": 30, "rankSpacing": 44}}}%%
flowchart TB
  DEP(["Deployer<br/>временные права"])

  subgraph L1["ETHEREUM (L1): hub уже работает"]
    direction TB
    MCMS(["Chainlink<br/>MCMS"])
    AGENT(["Lido DAO<br/>Agent"])
    EB(["Emergency<br/>Brakes"])
    TL1["LidoTimelock"]
    POOL1["Hub pool<br/>+ hooks + CCV"]
    NEWLB["NEW<br/>ERC20LockBox<br/>новой сети"]
  end

  subgraph L2["НОВАЯ СЕТЬ (L2)"]
    direction TB
    EXEC(["DAO-адрес сети<br/>governance executor"])
    TL2["NEW<br/>LidoTimelock"]
    POOL2["NEW<br/>TokenPool<br/>+ hooks + CCV"]
    TOKEN2[["NEW PROXY<br/>wstETH"]]
    TAR2["TokenAdmin<br/>Registry"]
  end

  DEP -->|"1. deploy<br/>2. настройка"| POOL2
  TL2 ==>|"2. owner"| POOL2
  POOL2 -->|"2. MINTER<br/>BURNER"| TOKEN2
  DEP -->|"3. регистрация,<br/>setPool"| TAR2
  TL2 -->|"3. admin записи<br/>wstETH"| TAR2
  EXEC ==>|"3. ADMIN_ROLE<br/>+ bypass"| TL2
  EXEC ==>|"1. proxy admin"| TOKEN2

  DEP -->|"4. deploy,<br/>допуск hub pool"| NEWLB
  MCMS -->|"5. proposal: принять lockbox<br/>6. proposal: подключить lane"| TL1
  TL1 ==>|"5. owner"| NEWLB
  TL1 ==>|"6. шесть<br/>вызовов"| POOL1
  POOL1 -->|"6. lockbox<br/>новой сети"| NEWLB
  EB -->|"может отменить<br/>5 и 6"| TL1
  AGENT ==>|"может исполнить<br/>5 и 6 сам"| TL1

  POOL1 <-.->|"7. lane открыт"| POOL2

  class AGENT,EB,EXEC lido
  class TOKEN2 lidoNewProxy
  class TL1,POOL1 lane
  class NEWLB,TL2,POOL2 laneNew
  class MCMS,TAR2 chainlink
  class DEP neutral

  style L1 fill:none,stroke:#64748B,stroke-width:2px
  style L2 fill:none,stroke:#64748B,stroke-width:2px

  classDef lido fill:#DBEAFE,stroke:#1D4ED8,stroke-width:1px,color:#0F172A
  classDef lidoProxy fill:#DBEAFE,stroke:#1D4ED8,stroke-width:3px,stroke-dasharray:6 4,color:#0F172A
  classDef lane fill:#DCFCE7,stroke:#15803D,stroke-width:1px,color:#052E16
  classDef chainlink fill:#FFEDD5,stroke:#C2410C,stroke-width:1px,color:#431407
  classDef chainlinkProxy fill:#FFEDD5,stroke:#C2410C,stroke-width:3px,stroke-dasharray:6 4,color:#431407
  classDef neutral fill:#E5E7EB,stroke:#6B7280,stroke-width:1px,color:#111827
  classDef laneNew fill:#DCFCE7,stroke:#15803D,stroke-width:4px,color:#052E16
  classDef lidoNewProxy fill:#DBEAFE,stroke:#1D4ED8,stroke-width:4px,stroke-dasharray:6 4,color:#0F172A
```

| Шаг | Кто | Сеть | Что происходит | Задержка |
| --- | --- | --- | --- | --- |
| 1 | Deployer | новая | Развёртывает wstETH за `TransparentUpgradeableProxy` (owner `ProxyAdmin` — DAO-адрес сети), `BurnMintTokenPool`, hooks, resolver и verifier, `LidoTimelock`, `CallProxy` | — |
| 2 | Deployer | новая | Настраивает lane к Ethereum: remote pool и token, rate limits, required CCV. Выдаёт pool `MINTER_ROLE` и `BURNER_ROLE`. Записывает blocked selectors. Передаёт owner всех контрактов `LidoTimelock` | — |
| 3 | Deployer | новая | Регистрирует token в `TokenAdminRegistry`, вызывает `setPool`, передаёт administrator записи `LidoTimelock`. Передаёт `DEFAULT_ADMIN_ROLE` token и `ADMIN_ROLE` timelock DAO-адресу сети и отказывается от своих ролей | — |
| 4 | Deployer | Ethereum | Развёртывает новый `ERC20LockBox`, допускает к нему действующий hub pool, предлагает owner действующему `LidoTimelock` | — |
| 5 | Chainlink MCMS, затем любой адрес | Ethereum | Proposal: `acceptOwnership` на новом lockbox | 3 дня |
| 6 | Chainlink MCMS, затем любой адрес | Ethereum | Proposal из шести вызовов, см. ниже | 3 дня |
| 7 | Операторы | обе | Проверка: новый lane читается как задумано, прежние lanes и их lockbox не изменились; пробный перевод | — |

Шесть вызовов шага 6, все от имени `LidoTimelock`:

1. `TokenPool.applyChainUpdates`: selector новой сети, её pool и token, rate limits
2. `TokenPool.applyTokenTransferFeeConfigUpdates`
3. `SiloedLockReleaseTokenPool.configureLockBoxes`: lockbox новой сети
4. `PausableAdvancedPoolHooks.applyCCVConfigUpdates`: required CCV для lane
5. `DummyMessageIdVerifier.applyRemoteChainConfigUpdates`
6. `VersionedVerifierResolver.applyOutboundImplementationUpdates`

Что нужно знать о подключении:

- **Что должно быть до начала.** Chainlink поддерживает сеть: в ней есть Router и `TokenAdminRegistry`. У DAO есть адрес
  в этой сети, через который исполняются её решения. Для OP Stack это `OptimismBridgeExecutor`; для сети другого типа
  такой путь нужно построить отдельно.
- **Рычаги Lido.** Шаги 5 и 6 — обычные proposals: Emergency Brakes может отменить любой из них, DAO может исполнить те же
  вызовы сама через bypass. На прежние lanes шаг 6 не действует: существующие selectors и lockbox в нём не упоминаются.
- **Если шаг 6 исполнен раньше, чем новая сеть готова выпускать token**, перевод Ethereum → новая сеть заблокирует wstETH
  в новом lockbox до этого момента. Так будет у Base, где token получает роли только по голосованию DAO;
  это окно нужно держать коротким.
- **Сеть, где token уже существует** (Base): token на шаге 1 не развёртывается, а шаг 3 для token и его записи
  в `TokenAdminRegistry` выполняет DAO голосованием вместе с обновлением legacy bridge:
  [upgrade path](targets/wsteth-base-migration-mainnet/docs/2026-10-26-upgrade-path.md).
- **Verifier и resolver на Ethereum.** В репетиции Base на шаге 4 вместе с lockbox развёртывались resolver и verifier,
  потому что у hub их ещё не было: пять перенесённых lanes работают без required CCV.
- **Статус.** Порядок отрепетирован на forks для Base. Отдельной автоматической команды «добавить сеть к работающему hub» нет:
  [MULTICHAIN-OPERATIONS.md](orchestration/wsteth-ccip/docs/MULTICHAIN-OPERATIONS.md).

## 9. Путь перевода Ethereum → Base

Стрелки здесь означают порядок вызовов, а не власть. Жирные стрелки — проверка proof.

Схема показывает проверку двумя CCV, «2 из 2»: так настроен Sepolia.
**В конфигурации mainnet target для Ethereum ↔ Base в списке required CCV сейчас один элемент — CCV lane,**
и за ним стоит `DummyMessageIdVerifier`. Что стоит в каждом слоте в каждой конфигурации, показано в таблице под схемой.

```mermaid
%%{init: {"flowchart": {"nodeSpacing": 30, "rankSpacing": 45}}}%%
flowchart TB
  USER(["Пользователь"])

  subgraph S["ETHEREUM (L1)"]
    direction TB
    R1["Router"]
    ON1["OnRamp<br/>собирает список CCV"]
    P1["SiloedLockReleaseTokenPool"]
    H1["Hooks: pause,<br/>список required CCV"]
    LBX["ERC20LockBox<br/>wstETH заблокирован"]
    subgraph C1["CCV на Ethereum"]
      direction TB
      L1C["CCV lane<br/>VersionedVerifierResolver<br/>→ DummyMessageIdVerifier"]
      K1C["CCV Chainlink<br/>resolver → verifier"]
    end
  end

  subgraph OFF["OFF-CHAIN"]
    direction TB
    OPL["Операторы CCV lane<br/>не выбраны"]
    OPK["Операторы<br/>CCV Chainlink"]
    EXE["Executor Chainlink<br/>сообщение + 2 proof"]
  end

  subgraph D["BASE (L2)"]
    direction TB
    OFF2{{"OffRamp<br/>ПРОВЕРКА «2 ИЗ 2»"}}
    subgraph C2["CCV на Base"]
      direction TB
      L2C["CCV lane<br/>VersionedVerifierResolver<br/>→ DummyMessageIdVerifier"]
      K2C["CCV Chainlink<br/>resolver → verifier"]
    end
    P2["BurnMintTokenPool"]
    H2["Hooks: pause,<br/>список required CCV"]
    T2[["PROXY · wstETH на Base"]]
  end

  USER -->|"1. ccipSend"| R1
  R1 -->|"2"| ON1
  ON1 -->|"3. getRequiredCCVs<br/>5. lockOrBurn"| P1
  P1 -->|"4. список CCV<br/>5. pause"| H1
  P1 -->|"6. deposit"| LBX
  ON1 -->|"7. forwardToVerifier"| L1C
  ON1 -->|"7. forwardToVerifier"| K1C
  ON1 -.->|"8. событие"| OPL
  ON1 -.->|"8. событие"| OPK
  ON1 -.->|"8. событие"| EXE
  OPL -.->|"9. proof"| EXE
  OPK -.->|"9. proof"| EXE
  EXE -->|"10. execute"| OFF2
  OFF2 -->|"11. getRequiredCCVs<br/>14. releaseOrMint"| P2
  P2 -->|"12. список CCV<br/>14. pause"| H2
  OFF2 ==>|"13. verifyMessage"| L2C
  OFF2 ==>|"13. verifyMessage"| K2C
  P2 -->|"15. mint"| T2

  classDef lido fill:#DBEAFE,stroke:#1D4ED8,stroke-width:1px,color:#0F172A
  classDef lidoProxy fill:#DBEAFE,stroke:#1D4ED8,stroke-width:3px,stroke-dasharray:6 4,color:#0F172A
  classDef lane fill:#DCFCE7,stroke:#15803D,stroke-width:1px,color:#052E16
  classDef chainlink fill:#FFEDD5,stroke:#C2410C,stroke-width:1px,color:#431407
  classDef neutral fill:#E5E7EB,stroke:#6B7280,stroke-width:1px,color:#111827
  classDef gate fill:#FEF08A,stroke:#A16207,stroke-width:4px,color:#422006

  class T2 lidoProxy
  class P1,H1,LBX,L1C,L2C,P2,H2 lane
  class R1,ON1,K1C,K2C,OPK,EXE chainlink
  class USER,OPL neutral
  class OFF2 gate

  style S fill:none,stroke:#64748B,stroke-width:2px
  style D fill:none,stroke:#64748B,stroke-width:2px
  style OFF fill:none,stroke:#94A3B8,stroke-dasharray:4 4
  style C1 fill:#A855F71A,stroke:#A855F7,stroke-dasharray:4 4
  style C2 fill:#A855F71A,stroke:#A855F7,stroke-dasharray:4 4
```

Обратный перевод зеркален: на Base pool сжигает wstETH, на Ethereum pool выдаёт wstETH из lockbox.
Проверку «2 из 2» тогда выполняет `OffRamp` на Ethereum по списку из hooks на Ethereum.

### Где участвует CCV

CCV — это пара контрактов в каждой сети: resolver, адрес которого записан в списке required CCV, и verifier, на который resolver указывает.
Proof создают операторы CCV вне блокчейна; контракты только проверяют его.

| Шаг | Сеть | Что происходит |
| --- | --- | --- |
| 3–4 | Ethereum | `OnRamp` вызывает `getRequiredCCVs` у pool с направлением Outbound; pool берёт список из hooks. `OnRamp` объединяет его с CCV, которые указал отправитель, и с `laneMandatedCCVs` своего lane |
| 7 | Ethereum | Для каждого CCV из списка `OnRamp` вызывает `getOutboundImplementation` у resolver, затем `forwardToVerifier` у verifier. Это уведомление и оплата, не проверка. Если resolver не знает сеть назначения, отправка ревертится |
| 8–9 | off-chain | Операторы каждого CCV независимо читают событие `CCIPMessageSent` и подписывают proof. Executor собирает сообщение и оба proof |
| 10 | Base | Executor вызывает `OffRamp.execute` с сообщением, списком CCV и списком proof. Вызвать `execute` может любой адрес |
| 11–12 | Base | `OffRamp` вызывает `getRequiredCCVs` у pool с направлением Inbound; pool берёт список из hooks на Base. К нему добавляются `laneMandatedCCVs`. Если для required CCV proof не передан, исполнение ревертится с `RequiredCCVMissing` |
| 13 | Base | Для каждого required CCV `OffRamp` вызывает `getInboundImplementation(proof)` у resolver: тот выбирает verifier по первым четырём байтам proof. Затем `OffRamp` сам вызывает `verifyMessage(message, messageId, proof)` у verifier. Невалидный proof — revert |
| 14–15 | Base | `releaseOrMint` вызывается только после того, как все проверки шага 13 прошли |

Три следствия:

- **«2 из 2» проверяет `OffRamp`, а не pool и не resolver.** Hooks только объявляют список; resolver только называет адрес verifier.
  Один resolver ведёт к одному verifier и не разветвляется на два.
- **Список для проверки берётся в сети назначения.** Его задаёт owner hooks, то есть `LidoTimelock`, вызовом `applyCCVConfigUpdates`.
  Поэтому состав «2 из 2» меняется операцией управления из раздела 7, отдельно для каждой сети и каждого направления.
- **Если проверка не прошла, wstETH не выпускается.** Сообщение получает состояние `FAILURE`, и `execute` можно вызвать повторно с полным набором proof.
  Недоступность любого из двух CCV задерживает доставку.

### Что стоит в слотах

| Конфигурация | CCV lane | CCV Chainlink | Сколько настоящих проверок |
| --- | --- | --- | --- |
| Mainnet target, Ethereum ↔ Base ([`ccv-policy.json`](targets/wsteth-base-migration-mainnet/config/ccv-policy.json)) | В списке; `DummyMessageIdVerifier` | Не в списке | 0 |
| Sepolia, развёрнуто 2026-11-04 ([`ccv-policy.json`](targets/wsteth-ccip-sepolia-mantle-dev/config/ccv-policy.json)) | В списке; `DummyMessageIdVerifier` | В списке; resolver `0x8f3ee3c77D2B27c32306a89D367654F959Db223D` | 1 |
| Намеченный итог ([MULTICHAIN-OPERATIONS.md](orchestration/wsteth-ccip/docs/MULTICHAIN-OPERATIONS.md#on-chain-actions-to-connect-nethermind)) | Nethermind вместо dummy | В списке | 2 |

Настройка mainnet target — стартовая, для репетиций на forks; решения о составе CCV для запуска в репозитории нет.

`DummyMessageIdVerifier` проверяет только формат proof и совпадение идентификатора сообщения. Такой proof может составить кто угодно,
поэтому слот с dummy не подтверждает, что событие было в исходной сети. Операторы CCV lane показаны серым, потому что они не выбраны.

Не проверено для mainnet: значения `laneMandatedCCVs` и `defaultCCVs` на `OnRamp` и `OffRamp` для Ethereum ↔ Base.
На Sepolia 2026-11-04 `laneMandatedCCVs` был пуст. Подробный разбор и что нужно для настоящей проверки:
[CCV-VERIFICATION-FLOW.md](orchestration/wsteth-ccip/docs/CCV-VERIFICATION-FLOW.md).

## 10. Чего на схемах нет

- **Пять действующих lanes Ethereum**: Bitlayer, 0G, Monad, MegaETH, Robinhood. Новый pool на Ethereum обслуживает
  их вместе с Base; из пяти lockbox один общий для Monad и MegaETH, по одному у Bitlayer, 0G, Robinhood и Base. Pool
  и token на этих пяти сетях и их владельцы здесь не описаны.
- **Четыре отключённые сети**: Ink, Plasma, Jovay, Abstract. Старый pool Chainlink числит их без remote pool
  (Ethereum, блок 26 391 413), переводы по ним не проходят. В новый pool они не переносятся.
  Перенос: [план миграции hub](targets/wsteth-base-migration-mainnet/CHAINLINK_HUB_MIGRATION_FORK_PLAN.md).
- **Порядок миграции Base во времени**. Legacy bridge проходит режимы LEGACY → MIGRATING → CCIP_ONLY.
  Связи с пометкой «до close()» временные: после `close()` L2 bridge отказывается от `MINTER_ROLE` и `BURNER_ROLE`,
  а допуск L1 bridge к lockbox DAO снимает отдельным решением. Порядок действий:
  [upgrade path](targets/wsteth-base-migration-mainnet/docs/2026-10-26-upgrade-path.md).
- **Путь от голосования до Agent** (Aragon Voting, Dual Governance): на схемах он свёрнут в один блок.
- **Кто владеет Router, OnRamp, OffRamp и RMN proxy внутри Chainlink**: репозиторий берёт их адреса из API Chainlink
  и не читает их owner. Стрелка «управляет» отражает договорённость, а не проверку.
- **Отличия Sepolia** (`targets/wsteth-ccip-sepolia-mantle-dev`): Lido core и Dual Governance развёрнуты с нуля;
  два spoke — Mantle Sepolia и Base Sepolia; token на spoke стоит за `TransparentUpgradeableProxy`; legacy bridge в этом target не участвует;
  в hooks требуются два CCV — resolver Chainlink и локальный resolver с dummy verifier; задержки сокращены до минут.

## 11. Источники и когда обновлять

| Что | Откуда |
| --- | --- |
| Владение, роли, blocked selectors, proxy admin | [`targets/wsteth-base-migration-mainnet/config/state-mate/wsteth.yaml`](targets/wsteth-base-migration-mainnet/config/state-mate/wsteth.yaml) |
| Адреса mainnet, акторы, даты чтения | [`targets/wsteth-base-migration-mainnet/target.json`](targets/wsteth-base-migration-mainnet/target.json), `config/chains/*.json` там же |
| Модель `LidoTimelock`, какие контракты развёртываются и как | `components/ccip/chains/evm/contracts/lido-hvmv/script/deployment/README.md`, `config/README.md` там же |
| Подключение сети к работающему hub | [`orchestration/wsteth-ccip/docs/MULTICHAIN-OPERATIONS.md`](orchestration/wsteth-ccip/docs/MULTICHAIN-OPERATIONS.md), `orchestration/wsteth-ccip/script/hub-migration/` |
| Порядок миграции, временные роли bridge | [`targets/wsteth-base-migration-mainnet/docs/2026-10-26-upgrade-path.md`](targets/wsteth-base-migration-mainnet/docs/2026-10-26-upgrade-path.md) |
| Путь сообщения и проверка CCV | [`orchestration/wsteth-ccip/docs/CCV-VERIFICATION-FLOW.md`](orchestration/wsteth-ccip/docs/CCV-VERIFICATION-FLOW.md) |

Обновлять этот файл нужно, когда меняется хотя бы одно из следующего: состав ролей `LidoTimelock` или список
blocked selectors; owner или proxy admin любого контракта из раздела 5; выбор держателей Emergency Brakes и
Chainlink MCMS для mainnet; набор required CCV; состав lanes на Ethereum; скрипты подключения новой сети.
