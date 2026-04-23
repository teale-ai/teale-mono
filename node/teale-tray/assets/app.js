const API_BASE = "http://127.0.0.1:11437";

const els = {
  headerLine: document.getElementById("header-line"),
  languageSelect: document.getElementById("language-select"),
  viewButtons: Array.from(document.querySelectorAll("[data-view-button]")),
  views: Array.from(document.querySelectorAll("[data-view]")),

  homeStatus: document.getElementById("home-status"),
  homeModel: document.getElementById("home-model"),
  homeBalance: document.getElementById("home-balance"),
  homeAccount: document.getElementById("home-account"),
  homeOpenSupply: document.getElementById("home-open-supply"),
  homeOpenDemand: document.getElementById("home-open-demand"),
  homeOpenWallet: document.getElementById("home-open-wallet"),
  homeOpenAccount: document.getElementById("home-open-account"),

  statusChip: document.getElementById("status-chip"),
  statusLine: document.getElementById("status-line"),
  deviceName: document.getElementById("device-name"),
  deviceRam: document.getElementById("device-ram"),
  deviceBackend: document.getElementById("device-backend"),
  devicePower: document.getElementById("device-power"),
  currentModel: document.getElementById("current-model"),
  unloadButton: document.getElementById("unload-button"),
  supplyEarningRate: document.getElementById("supply-earning-rate"),
  supplySessionCredits: document.getElementById("supply-session-credits"),
  supplyWalletBalance: document.getElementById("supply-wallet-balance"),
  supplyWalletLink: document.getElementById("supply-wallet-link"),
  recommendedName: document.getElementById("recommended-name"),
  recommendedMeta: document.getElementById("recommended-meta"),
  recommendedError: document.getElementById("recommended-error"),
  recommendedAction: document.getElementById("recommended-action"),
  transferPanel: document.getElementById("transfer-panel"),
  transferLabel: document.getElementById("transfer-label"),
  transferPercent: document.getElementById("transfer-percent"),
  transferBarText: document.getElementById("transfer-bar-text"),
  modelsList: document.getElementById("models-list"),

  localBaseUrl: document.getElementById("local-base-url"),
  localModelId: document.getElementById("local-model-id"),
  localCurl: document.getElementById("local-curl"),
  localCurlCopy: document.getElementById("local-curl-copy"),
  networkModelTableBody: document.getElementById("network-model-table-body"),
  networkModelEmpty: document.getElementById("network-model-empty"),
  networkModelSortButtons: Array.from(document.querySelectorAll("[data-model-sort]")),
  networkBaseUrl: document.getElementById("network-base-url"),
  networkToken: document.getElementById("network-token"),
  networkTokenNote: document.getElementById("network-token-note"),
  networkSelectedModel: document.getElementById("network-selected-model"),
  networkCurl: document.getElementById("network-curl"),
  networkTokenCopy: document.getElementById("network-token-copy"),
  networkCurlCopy: document.getElementById("network-curl-copy"),

  walletBalance: document.getElementById("wallet-balance"),
  walletUsdc: document.getElementById("wallet-usdc"),
  walletSessionCredits: document.getElementById("wallet-session-credits"),
  walletCreditsToday: document.getElementById("wallet-credits-today"),
  walletEarned: document.getElementById("wallet-earned"),
  walletSpent: document.getElementById("wallet-spent"),
  walletRequests: document.getElementById("wallet-requests"),
  walletSince: document.getElementById("wallet-since"),
  walletRate: document.getElementById("wallet-rate"),
  walletNote: document.getElementById("wallet-note"),
  sendAsset: document.getElementById("send-asset"),
  sendRecipient: document.getElementById("send-recipient"),
  sendAmount: document.getElementById("send-amount"),
  sendMemo: document.getElementById("send-memo"),
  sendSubmit: document.getElementById("send-submit"),
  sendNote: document.getElementById("send-note"),
  ledgerExport: document.getElementById("ledger-export"),
  ledgerList: document.getElementById("ledger-list"),

  authStatus: document.getElementById("auth-status"),
  authUser: document.getElementById("auth-user"),
  authGithubButton: document.getElementById("auth-github-button"),
  authGoogleButton: document.getElementById("auth-google-button"),
  authSignoutButton: document.getElementById("auth-signout-button"),
  authPhonePanel: document.getElementById("auth-phone-panel"),
  authPhoneInput: document.getElementById("auth-phone-input"),
  authPhoneSendButton: document.getElementById("auth-phone-send-button"),
  authPhoneCodeInput: document.getElementById("auth-phone-code-input"),
  authPhoneVerifyButton: document.getElementById("auth-phone-verify-button"),
  authNote: document.getElementById("auth-note"),
  accountId: document.getElementById("account-id"),
  accountEmail: document.getElementById("account-email"),
  accountPhone: document.getElementById("account-phone"),
  accountWalletBalance: document.getElementById("account-wallet-balance"),
  accountWalletUsdc: document.getElementById("account-wallet-usdc"),
  accountWalletNote: document.getElementById("account-wallet-note"),
  accountIdentities: document.getElementById("account-identities"),
  accountDevices: document.getElementById("account-devices"),
  accountDevicesEmpty: document.getElementById("account-devices-empty"),
  accountSendAsset: document.getElementById("account-send-asset"),
  accountSendRecipient: document.getElementById("account-send-recipient"),
  accountSendAmount: document.getElementById("account-send-amount"),
  accountSendMemo: document.getElementById("account-send-memo"),
  accountSendSubmit: document.getElementById("account-send-submit"),
  accountSendNote: document.getElementById("account-send-note"),
};

const LANGUAGE_STORAGE_KEY = "teale.language";
const translations = {
  en: {
    "nav.home": "teale.com",
    "nav.supply": "supply",
    "nav.demand": "demand",
    "nav.wallet": "wallet",
    "nav.account": "account",
    "language.label": "language",
    "view.home.description": "distributed ai inference supply and demand",
    "view.supply.description": "earn teale credits by supplying ai inference to users around the world",
    "view.demand.description": "use local models for free or buy and spend credits for more powerful models",
    "view.wallet.description": "Device balances, send assets, and ledger history",
    "view.account.description": "account details, balances, send assets, and linked devices.",
    "home.prompt.overview": "overview",
    "home.lede": "Teale turns this machine into a supply node and a demand client at the same time.",
    "home.action.supply": "Open supply",
    "home.action.demand": "Open demand",
    "home.action.wallet": "Open wallet",
    "home.action.account": "Open account",
    "supply.prompt.status": "status",
    "supply.prompt.earnings": "earnings",
    "supply.prompt.recommended": "recommended",
    "supply.prompt.transfer": "transfer",
    "supply.prompt.catalog": "catalog",
    "supply.wallet.note": "The wallet view shows the balance grow in real time.",
    "supply.wallet.action": "Open wallet",
    "demand.prompt.local": "local inference",
    "demand.prompt.networkModels": "teale network models",
    "demand.prompt.network": "teale network",
    "demand.action.copyLocalCurl": "Copy local curl",
    "demand.action.copyBearer": "Copy bearer token",
    "demand.action.copyNetworkCurl": "Copy network curl",
    "wallet.prompt.balances": "balances",
    "wallet.prompt.send": "send",
    "wallet.prompt.ledger": "ledger",
    "wallet.asset.credits": "Teale credits",
    "wallet.asset.usdc": "USDC",
    "wallet.input.recipient": "device id, key, phone, or github username",
    "wallet.action.sendSoon": "Send coming soon",
    "wallet.send.note": "Transfers are not wired in the Windows companion backend yet. This will eventually support device IDs, keys, account phone numbers, and GitHub usernames.",
    "wallet.action.export": "Export CSV",
    "account.prompt.account": "account",
    "account.prompt.wallet": "account wallet",
    "account.prompt.details": "details",
    "account.prompt.devices": "devices",
    "account.phone": "Phone",
    "account.code": "Code",
    "account.input.phone": "+1 555 123 4567",
    "account.input.code": "123456",
    "account.auth.note.default": "Sign in to link this machine to a person. Device wallet earnings continue working without human sign-in.",
    "account.send.note": "Account wallet transfers are not wired in the Windows companion backend yet.",
    "common.asset": "Asset",
    "common.recipient": "Recipient",
    "common.amount": "Amount",
    "common.memo": "Memo",
    "common.amountPlaceholder": "0",
    "common.memoPlaceholder": "optional note",
    "common.waitingLocalService": "Waiting for the local Teale service on this PC.",
    "common.noModelLoaded": "No model loaded",
    "common.syncing": "Syncing...",
    "footer.tagline": "teale - distributed ai inference for the world",
    "auth.status.notConfigured": "Sign-in not configured",
    "auth.status.notSignedIn": "Not signed in",
    "auth.status.signedIn": "Signed in",
    "auth.user.configure": "Add Supabase config to the node to enable account sign-in.",
    "auth.user.prompt": "Use GitHub, Google, or SMS to attach a person to this machine.",
    "auth.note.walletStillWorks": "Wallet and supply still work through Teale device auth.",
    "auth.note.claimsDevice": "Phone, GitHub, or Google sign-in claims this device for one account.",
    "auth.note.phoneCanLink": "GitHub and Google can be linked onto this phone account.",
    "auth.note.allLinked": "This account already has phone, GitHub, and Google linked.",
    "auth.note.phoneLinkNotYet": "Phone linking onto an existing account is not enabled in this companion yet.",
    "auth.button.signInGithub": "Sign in with GitHub",
    "auth.button.signInGoogle": "Sign in with Google",
    "auth.button.linkGithub": "Link GitHub",
    "auth.button.linkGoogle": "Link Google",
    "auth.button.githubLinked": "GitHub linked",
    "auth.button.googleLinked": "Google linked",
    "auth.button.signOut": "Sign out",
    "auth.button.sendSms": "Send SMS code",
    "auth.button.verifyCode": "Verify code",
    "auth.alert.smsSent": "SMS code sent.",
    "auth.error.enterPhone": "Enter a phone number first.",
    "auth.error.enterPhoneAndCode": "Enter both the phone number and the SMS code.",
    "provider.github": "GitHub",
    "provider.google": "Google",
    "provider.phone": "phone",
    "provider.email": "email",
    "supply.status.loadingSelected": "Loading the selected local model...",
    "supply.status.unloadingCurrent": "Unloading the current local model...",
    "model.action.loading": "Loading",
    "model.action.unloading": "Unloading",
    "model.action.servingNow": "Serving now",
    "model.action.unavailable": "Unavailable",
    "model.action.loadAndSupply": "Load and start supplying",
    "model.action.retryDownload": "Retry download",
    "model.action.downloadAndSupply": "Download and start supplying",
    "model.action.loaded": "Loaded",
    "model.action.downloading": "Downloading",
    "model.action.busy": "Busy",
    "model.action.load": "Load",
    "model.action.retry": "Retry",
    "model.action.download": "Download",
    "account.wallet.note.summary": "Sweep device balances here, then send from the account wallet.",
    "account.wallet.note.pending": "This account wallet appears once the device is linked locally.",
    "account.wallet.note.signedOut": "Sign in to link this device to an account wallet.",
    "account.devices.empty.signedOut": "Sign in to view devices on this account.",
    "account.devices.empty.none": "No linked devices found yet.",
    "supply.recommended.none": "No compatible model found",
    "supply.recommended.noneMeta": "This machine does not currently fit the Windows catalog.",
    "supply.recommended.waiting": "Waiting for the local Teale service...",
    "supply.recommended.waitingMeta": "Once Teale responds locally, Teale will recommend the best model for this machine.",
    "supply.models.noneYet": "No model data yet.",
    "supply.models.noneCompatible": "No compatible models are available for this device yet.",
  },
  "zh-Hans": {
    "nav.home": "teale.com",
    "nav.supply": "供给",
    "nav.demand": "需求",
    "nav.wallet": "钱包",
    "nav.account": "账户",
    "language.label": "语言",
    "view.home.description": "分布式 AI 推理供给与需求",
    "view.supply.description": "通过为全球用户提供 AI 推理来赚取 Teale credits",
    "view.demand.description": "免费使用本地模型，或购买并花费 credits 使用更强大的模型",
    "view.wallet.description": "设备余额、资产发送和账本历史",
    "view.account.description": "账户详情、余额、资产发送和已关联设备。",
    "home.prompt.overview": "概览",
    "home.lede": "Teale 让这台机器同时成为供给节点和需求客户端。",
    "home.action.supply": "打开供给",
    "home.action.demand": "打开需求",
    "home.action.wallet": "打开钱包",
    "home.action.account": "打开账户",
    "supply.prompt.status": "状态",
    "supply.prompt.earnings": "收益",
    "supply.prompt.recommended": "推荐",
    "supply.prompt.transfer": "传输",
    "supply.prompt.catalog": "目录",
    "supply.wallet.note": "钱包页面会实时显示余额增长。",
    "supply.wallet.action": "打开钱包",
    "demand.prompt.local": "本地推理",
    "demand.prompt.networkModels": "Teale 网络模型",
    "demand.prompt.network": "Teale 网络",
    "demand.action.copyLocalCurl": "复制本地 curl",
    "demand.action.copyBearer": "复制 bearer token",
    "demand.action.copyNetworkCurl": "复制网络 curl",
    "wallet.prompt.balances": "余额",
    "wallet.prompt.send": "发送",
    "wallet.prompt.ledger": "账本",
    "wallet.asset.credits": "Teale credits",
    "wallet.asset.usdc": "USDC",
    "wallet.input.recipient": "device id、密钥、手机号或 GitHub 用户名",
    "wallet.action.sendSoon": "发送即将上线",
    "wallet.send.note": "Windows companion 后端尚未接通转账。后续将支持 device ID、密钥、账户手机号和 GitHub 用户名。",
    "wallet.action.export": "导出 CSV",
    "account.prompt.account": "账户",
    "account.prompt.wallet": "账户钱包",
    "account.prompt.details": "详情",
    "account.prompt.devices": "设备",
    "account.phone": "手机号",
    "account.code": "验证码",
    "account.input.phone": "+86 138 0013 8000",
    "account.input.code": "123456",
    "account.auth.note.default": "登录后可将这台机器关联到个人账户。即使不做人类登录，设备钱包收益仍会继续工作。",
    "account.send.note": "Windows companion 后端尚未接通账户钱包转账。",
    "common.asset": "资产",
    "common.recipient": "接收方",
    "common.amount": "数量",
    "common.memo": "备注",
    "common.amountPlaceholder": "0",
    "common.memoPlaceholder": "可选备注",
    "common.waitingLocalService": "正在等待这台电脑上的本地 Teale 服务。",
    "common.noModelLoaded": "未加载模型",
    "common.syncing": "同步中...",
    "footer.tagline": "teale - 面向世界的分布式 AI 推理",
    "auth.status.notConfigured": "未配置登录",
    "auth.status.notSignedIn": "未登录",
    "auth.status.signedIn": "已登录",
    "auth.user.configure": "请在节点中添加 Supabase 配置以启用账户登录。",
    "auth.user.prompt": "使用 GitHub、Google 或短信，将个人账户关联到这台机器。",
    "auth.note.walletStillWorks": "钱包和供给仍可通过 Teale 设备认证继续工作。",
    "auth.note.claimsDevice": "手机号、GitHub 或 Google 登录会将此设备归属到一个账户。",
    "auth.note.phoneCanLink": "GitHub 和 Google 可以关联到这个手机号账户。",
    "auth.note.allLinked": "此账户已关联手机号、GitHub 和 Google。",
    "auth.note.phoneLinkNotYet": "此 companion 暂不支持在现有账户上补充手机号关联。",
    "auth.button.signInGithub": "使用 GitHub 登录",
    "auth.button.signInGoogle": "使用 Google 登录",
    "auth.button.linkGithub": "关联 GitHub",
    "auth.button.linkGoogle": "关联 Google",
    "auth.button.githubLinked": "GitHub 已关联",
    "auth.button.googleLinked": "Google 已关联",
    "auth.button.signOut": "退出登录",
    "auth.button.sendSms": "发送短信验证码",
    "auth.button.verifyCode": "验证验证码",
    "auth.alert.smsSent": "短信验证码已发送。",
    "auth.error.enterPhone": "请先输入手机号。",
    "auth.error.enterPhoneAndCode": "请输入手机号和短信验证码。",
    "provider.github": "GitHub",
    "provider.google": "Google",
    "provider.phone": "手机",
    "provider.email": "邮箱",
    "supply.status.loadingSelected": "正在加载所选本地模型...",
    "supply.status.unloadingCurrent": "正在卸载当前本地模型...",
    "model.action.loading": "加载中",
    "model.action.unloading": "卸载中",
    "model.action.servingNow": "正在服务",
    "model.action.unavailable": "不可用",
    "model.action.loadAndSupply": "加载并开始供给",
    "model.action.retryDownload": "重试下载",
    "model.action.downloadAndSupply": "下载并开始供给",
    "model.action.loaded": "已加载",
    "model.action.downloading": "下载中",
    "model.action.busy": "忙碌中",
    "model.action.load": "加载",
    "model.action.retry": "重试",
    "model.action.download": "下载",
    "account.wallet.note.summary": "先把设备余额归集到这里，再从账户钱包发送。",
    "account.wallet.note.pending": "本地完成设备关联后，这里会显示账户钱包。",
    "account.wallet.note.signedOut": "登录后即可将此设备关联到账户钱包。",
    "account.devices.empty.signedOut": "登录后即可查看此账户上的设备。",
    "account.devices.empty.none": "暂未发现已关联设备。",
    "supply.recommended.none": "未找到兼容模型",
    "supply.recommended.noneMeta": "这台机器目前不符合 Windows 模型目录要求。",
    "supply.recommended.waiting": "正在等待本地 Teale 服务...",
    "supply.recommended.waitingMeta": "本地服务响应后，Teale 会为这台机器推荐最佳模型。",
    "supply.models.noneYet": "暂无模型数据。",
    "supply.models.noneCompatible": "这台设备暂时没有兼容模型。",
  },
  "pt-BR": {
    "nav.home": "teale.com",
    "nav.supply": "oferta",
    "nav.demand": "demanda",
    "nav.wallet": "carteira",
    "nav.account": "conta",
    "language.label": "idioma",
    "view.home.description": "oferta e demanda de inferência distribuída de IA",
    "view.supply.description": "ganhe créditos Teale fornecendo inferência de IA para usuários no mundo todo",
    "view.demand.description": "use modelos locais de graça ou compre e gaste créditos em modelos mais poderosos",
    "view.wallet.description": "Saldos do dispositivo, envio de ativos e histórico do razão",
    "view.account.description": "detalhes da conta, saldos, envio de ativos e dispositivos vinculados.",
    "home.prompt.overview": "visão geral",
    "home.lede": "O Teale transforma esta máquina em um nó de oferta e um cliente de demanda ao mesmo tempo.",
    "home.action.supply": "Abrir oferta",
    "home.action.demand": "Abrir demanda",
    "home.action.wallet": "Abrir carteira",
    "home.action.account": "Abrir conta",
    "supply.prompt.status": "status",
    "supply.prompt.earnings": "ganhos",
    "supply.prompt.recommended": "recomendado",
    "supply.prompt.transfer": "transferência",
    "supply.prompt.catalog": "catálogo",
    "supply.wallet.note": "A carteira mostra o saldo crescendo em tempo real.",
    "supply.wallet.action": "Abrir carteira",
    "demand.prompt.local": "inferência local",
    "demand.prompt.networkModels": "modelos da rede Teale",
    "demand.prompt.network": "rede Teale",
    "demand.action.copyLocalCurl": "Copiar curl local",
    "demand.action.copyBearer": "Copiar bearer token",
    "demand.action.copyNetworkCurl": "Copiar curl da rede",
    "wallet.prompt.balances": "saldos",
    "wallet.prompt.send": "enviar",
    "wallet.prompt.ledger": "razão",
    "wallet.asset.credits": "Créditos Teale",
    "wallet.asset.usdc": "USDC",
    "wallet.input.recipient": "id do dispositivo, chave, telefone ou usuário do GitHub",
    "wallet.action.sendSoon": "Envio em breve",
    "wallet.send.note": "Transferências ainda não estão conectadas no backend do companion para Windows. No futuro isso vai aceitar IDs de dispositivo, chaves, telefones da conta e nomes de usuário do GitHub.",
    "wallet.action.export": "Exportar CSV",
    "account.prompt.account": "conta",
    "account.prompt.wallet": "carteira da conta",
    "account.prompt.details": "detalhes",
    "account.prompt.devices": "dispositivos",
    "account.phone": "Telefone",
    "account.code": "Código",
    "account.input.phone": "+55 11 99999-9999",
    "account.input.code": "123456",
    "account.auth.note.default": "Faça login para vincular esta máquina a uma pessoa. Os ganhos da carteira do dispositivo continuam funcionando sem login humano.",
    "account.send.note": "As transferências da carteira da conta ainda não estão conectadas no backend do companion para Windows.",
    "common.asset": "Ativo",
    "common.recipient": "Destinatário",
    "common.amount": "Valor",
    "common.memo": "Memo",
    "common.amountPlaceholder": "0",
    "common.memoPlaceholder": "nota opcional",
    "common.waitingLocalService": "Aguardando o serviço local do Teale neste PC.",
    "common.noModelLoaded": "Nenhum modelo carregado",
    "common.syncing": "Sincronizando...",
    "footer.tagline": "teale - inferência distribuída de IA para o mundo",
    "auth.status.notConfigured": "Login não configurado",
    "auth.status.notSignedIn": "Sem login",
    "auth.status.signedIn": "Conectado",
    "auth.user.configure": "Adicione a configuração do Supabase ao nó para habilitar o login da conta.",
    "auth.user.prompt": "Use GitHub, Google ou SMS para vincular uma pessoa a esta máquina.",
    "auth.note.walletStillWorks": "Carteira e oferta continuam funcionando via autenticação do dispositivo Teale.",
    "auth.note.claimsDevice": "Login por telefone, GitHub ou Google vincula este dispositivo a uma conta.",
    "auth.note.phoneCanLink": "GitHub e Google podem ser vinculados a esta conta por telefone.",
    "auth.note.allLinked": "Esta conta já tem telefone, GitHub e Google vinculados.",
    "auth.note.phoneLinkNotYet": "Vincular telefone a uma conta existente ainda não está disponível neste companion.",
    "auth.button.signInGithub": "Entrar com GitHub",
    "auth.button.signInGoogle": "Entrar com Google",
    "auth.button.linkGithub": "Vincular GitHub",
    "auth.button.linkGoogle": "Vincular Google",
    "auth.button.githubLinked": "GitHub vinculado",
    "auth.button.googleLinked": "Google vinculado",
    "auth.button.signOut": "Sair",
    "auth.button.sendSms": "Enviar código por SMS",
    "auth.button.verifyCode": "Verificar código",
    "auth.alert.smsSent": "Código SMS enviado.",
    "auth.error.enterPhone": "Digite um número de telefone primeiro.",
    "auth.error.enterPhoneAndCode": "Digite o telefone e o código SMS.",
    "provider.github": "GitHub",
    "provider.google": "Google",
    "provider.phone": "telefone",
    "provider.email": "email",
    "supply.status.loadingSelected": "Carregando o modelo local selecionado...",
    "supply.status.unloadingCurrent": "Descarregando o modelo local atual...",
    "model.action.loading": "Carregando",
    "model.action.unloading": "Descarregando",
    "model.action.servingNow": "Servindo agora",
    "model.action.unavailable": "Indisponível",
    "model.action.loadAndSupply": "Carregar e começar a ofertar",
    "model.action.retryDownload": "Tentar download novamente",
    "model.action.downloadAndSupply": "Baixar e começar a ofertar",
    "model.action.loaded": "Carregado",
    "model.action.downloading": "Baixando",
    "model.action.busy": "Ocupado",
    "model.action.load": "Carregar",
    "model.action.retry": "Tentar novamente",
    "model.action.download": "Baixar",
    "account.wallet.note.summary": "Faça sweep dos saldos dos dispositivos para cá e depois envie pela carteira da conta.",
    "account.wallet.note.pending": "Esta carteira da conta aparece quando o dispositivo for vinculado localmente.",
    "account.wallet.note.signedOut": "Faça login para vincular este dispositivo a uma carteira de conta.",
    "account.devices.empty.signedOut": "Faça login para ver os dispositivos desta conta.",
    "account.devices.empty.none": "Nenhum dispositivo vinculado encontrado ainda.",
    "supply.recommended.none": "Nenhum modelo compatível encontrado",
    "supply.recommended.noneMeta": "Esta máquina não atende ao catálogo do Windows no momento.",
    "supply.recommended.waiting": "Aguardando o serviço local do Teale...",
    "supply.recommended.waitingMeta": "Quando o Teale responder localmente, ele vai recomendar o melhor modelo para esta máquina.",
    "supply.models.noneYet": "Ainda não há dados de modelos.",
    "supply.models.noneCompatible": "Ainda não há modelos compatíveis para este dispositivo.",
  },
  es: {
    "nav.home": "teale.com",
    "nav.supply": "oferta",
    "nav.demand": "demanda",
    "nav.wallet": "cartera",
    "nav.account": "cuenta",
    "language.label": "idioma",
    "view.home.description": "oferta y demanda de inferencia distribuida de IA",
    "view.supply.description": "gana créditos Teale ofreciendo inferencia de IA a usuarios de todo el mundo",
    "view.demand.description": "usa modelos locales gratis o compra y gasta créditos en modelos más potentes",
    "view.wallet.description": "Saldos del dispositivo, envío de activos e historial del libro",
    "view.account.description": "detalles de la cuenta, saldos, envío de activos y dispositivos vinculados.",
    "home.prompt.overview": "resumen",
    "home.lede": "Teale convierte esta máquina en un nodo de oferta y un cliente de demanda al mismo tiempo.",
    "home.action.supply": "Abrir oferta",
    "home.action.demand": "Abrir demanda",
    "home.action.wallet": "Abrir cartera",
    "home.action.account": "Abrir cuenta",
    "supply.prompt.status": "estado",
    "supply.prompt.earnings": "ganancias",
    "supply.prompt.recommended": "recomendado",
    "supply.prompt.transfer": "transferencia",
    "supply.prompt.catalog": "catálogo",
    "supply.wallet.note": "La cartera muestra el saldo creciendo en tiempo real.",
    "supply.wallet.action": "Abrir cartera",
    "demand.prompt.local": "inferencia local",
    "demand.prompt.networkModels": "modelos de la red Teale",
    "demand.prompt.network": "red Teale",
    "demand.action.copyLocalCurl": "Copiar curl local",
    "demand.action.copyBearer": "Copiar bearer token",
    "demand.action.copyNetworkCurl": "Copiar curl de red",
    "wallet.prompt.balances": "saldos",
    "wallet.prompt.send": "enviar",
    "wallet.prompt.ledger": "libro",
    "wallet.asset.credits": "Créditos Teale",
    "wallet.asset.usdc": "USDC",
    "wallet.input.recipient": "id del dispositivo, clave, teléfono o usuario de GitHub",
    "wallet.action.sendSoon": "Envío próximamente",
    "wallet.send.note": "Las transferencias todavía no están conectadas en el backend del companion de Windows. En el futuro esto aceptará IDs de dispositivo, claves, teléfonos de cuenta y nombres de usuario de GitHub.",
    "wallet.action.export": "Exportar CSV",
    "account.prompt.account": "cuenta",
    "account.prompt.wallet": "cartera de la cuenta",
    "account.prompt.details": "detalles",
    "account.prompt.devices": "dispositivos",
    "account.phone": "Teléfono",
    "account.code": "Código",
    "account.input.phone": "+34 600 123 456",
    "account.input.code": "123456",
    "account.auth.note.default": "Inicia sesión para vincular esta máquina a una persona. Las ganancias de la cartera del dispositivo siguen funcionando sin inicio de sesión humano.",
    "account.send.note": "Las transferencias de la cartera de la cuenta todavía no están conectadas en el backend del companion de Windows.",
    "common.asset": "Activo",
    "common.recipient": "Destinatario",
    "common.amount": "Cantidad",
    "common.memo": "Memo",
    "common.amountPlaceholder": "0",
    "common.memoPlaceholder": "nota opcional",
    "common.waitingLocalService": "Esperando el servicio local de Teale en esta PC.",
    "common.noModelLoaded": "Ningún modelo cargado",
    "common.syncing": "Sincronizando...",
    "footer.tagline": "teale - inferencia distribuida de IA para el mundo",
    "auth.status.notConfigured": "Inicio de sesión no configurado",
    "auth.status.notSignedIn": "Sin iniciar sesión",
    "auth.status.signedIn": "Sesión iniciada",
    "auth.user.configure": "Agrega la configuración de Supabase al nodo para habilitar el inicio de sesión de la cuenta.",
    "auth.user.prompt": "Usa GitHub, Google o SMS para vincular una persona a esta máquina.",
    "auth.note.walletStillWorks": "La cartera y la oferta siguen funcionando mediante la autenticación del dispositivo Teale.",
    "auth.note.claimsDevice": "El inicio de sesión por teléfono, GitHub o Google vincula este dispositivo a una sola cuenta.",
    "auth.note.phoneCanLink": "GitHub y Google pueden vincularse a esta cuenta de teléfono.",
    "auth.note.allLinked": "Esta cuenta ya tiene teléfono, GitHub y Google vinculados.",
    "auth.note.phoneLinkNotYet": "Vincular teléfono a una cuenta existente todavía no está habilitado en este companion.",
    "auth.button.signInGithub": "Iniciar con GitHub",
    "auth.button.signInGoogle": "Iniciar con Google",
    "auth.button.linkGithub": "Vincular GitHub",
    "auth.button.linkGoogle": "Vincular Google",
    "auth.button.githubLinked": "GitHub vinculado",
    "auth.button.googleLinked": "Google vinculado",
    "auth.button.signOut": "Cerrar sesión",
    "auth.button.sendSms": "Enviar código SMS",
    "auth.button.verifyCode": "Verificar código",
    "auth.alert.smsSent": "Código SMS enviado.",
    "auth.error.enterPhone": "Ingresa primero un número de teléfono.",
    "auth.error.enterPhoneAndCode": "Ingresa el teléfono y el código SMS.",
    "provider.github": "GitHub",
    "provider.google": "Google",
    "provider.phone": "teléfono",
    "provider.email": "correo",
    "supply.status.loadingSelected": "Cargando el modelo local seleccionado...",
    "supply.status.unloadingCurrent": "Descargando el modelo local actual...",
    "model.action.loading": "Cargando",
    "model.action.unloading": "Descargando",
    "model.action.servingNow": "Sirviendo ahora",
    "model.action.unavailable": "No disponible",
    "model.action.loadAndSupply": "Cargar y empezar a ofrecer",
    "model.action.retryDownload": "Reintentar descarga",
    "model.action.downloadAndSupply": "Descargar y empezar a ofrecer",
    "model.action.loaded": "Cargado",
    "model.action.downloading": "Descargando",
    "model.action.busy": "Ocupado",
    "model.action.load": "Cargar",
    "model.action.retry": "Reintentar",
    "model.action.download": "Descargar",
    "account.wallet.note.summary": "Haz sweep de los saldos de los dispositivos aquí y luego envía desde la cartera de la cuenta.",
    "account.wallet.note.pending": "Esta cartera de cuenta aparece cuando el dispositivo quede vinculado localmente.",
    "account.wallet.note.signedOut": "Inicia sesión para vincular este dispositivo a una cartera de cuenta.",
    "account.devices.empty.signedOut": "Inicia sesión para ver los dispositivos de esta cuenta.",
    "account.devices.empty.none": "Todavía no se encontraron dispositivos vinculados.",
    "supply.recommended.none": "No se encontró un modelo compatible",
    "supply.recommended.noneMeta": "Esta máquina no encaja en el catálogo de Windows por ahora.",
    "supply.recommended.waiting": "Esperando el servicio local de Teale...",
    "supply.recommended.waitingMeta": "Cuando Teale responda localmente, recomendará el mejor modelo para esta máquina.",
    "supply.models.noneYet": "Todavía no hay datos de modelos.",
    "supply.models.noneCompatible": "Todavía no hay modelos compatibles para este dispositivo.",
  },
  "fil-PH": {
    "nav.home": "teale.com",
    "nav.supply": "suplay",
    "nav.demand": "demand",
    "nav.wallet": "wallet",
    "nav.account": "account",
    "language.label": "wika",
    "view.home.description": "distributed ai inference supply at demand",
    "view.supply.description": "kumita ng Teale credits sa pag-supply ng AI inference sa mga user sa buong mundo",
    "view.demand.description": "gumamit ng local models nang libre o bumili at gumastos ng credits para sa mas malalakas na modelo",
    "view.wallet.description": "Mga balanse ng device, pagpapadala ng assets, at ledger history",
    "view.account.description": "mga detalye ng account, mga balanse, pagpapadala ng assets, at mga naka-link na device.",
    "home.prompt.overview": "overview",
    "home.lede": "Ginagawang sabay na supply node at demand client ng Teale ang makinang ito.",
    "home.action.supply": "Buksan ang supply",
    "home.action.demand": "Buksan ang demand",
    "home.action.wallet": "Buksan ang wallet",
    "home.action.account": "Buksan ang account",
    "supply.prompt.status": "status",
    "supply.prompt.earnings": "kita",
    "supply.prompt.recommended": "recommended",
    "supply.prompt.transfer": "transfer",
    "supply.prompt.catalog": "catalog",
    "supply.wallet.note": "Makikita sa wallet ang paglaki ng balanse nang live.",
    "supply.wallet.action": "Buksan ang wallet",
    "demand.prompt.local": "local inference",
    "demand.prompt.networkModels": "mga model sa Teale network",
    "demand.prompt.network": "Teale network",
    "demand.action.copyLocalCurl": "Kopyahin ang local curl",
    "demand.action.copyBearer": "Kopyahin ang bearer token",
    "demand.action.copyNetworkCurl": "Kopyahin ang network curl",
    "wallet.prompt.balances": "mga balanse",
    "wallet.prompt.send": "magpadala",
    "wallet.prompt.ledger": "ledger",
    "wallet.asset.credits": "Teale credits",
    "wallet.asset.usdc": "USDC",
    "wallet.input.recipient": "device id, key, phone, o GitHub username",
    "wallet.action.sendSoon": "Papunta na ang send",
    "wallet.send.note": "Hindi pa naka-wire ang transfers sa Windows companion backend. Sa susunod susuporta ito sa device IDs, keys, account phone numbers, at GitHub usernames.",
    "wallet.action.export": "I-export ang CSV",
    "account.prompt.account": "account",
    "account.prompt.wallet": "account wallet",
    "account.prompt.details": "detalye",
    "account.prompt.devices": "mga device",
    "account.phone": "Phone",
    "account.code": "Code",
    "account.input.phone": "+63 917 123 4567",
    "account.input.code": "123456",
    "account.auth.note.default": "Mag-sign in para i-link ang makinang ito sa isang tao. Patuloy pa ring gagana ang kita ng device wallet kahit walang human sign-in.",
    "account.send.note": "Hindi pa naka-wire ang account wallet transfers sa Windows companion backend.",
    "common.asset": "Asset",
    "common.recipient": "Tatanggap",
    "common.amount": "Halaga",
    "common.memo": "Memo",
    "common.amountPlaceholder": "0",
    "common.memoPlaceholder": "opsyonal na note",
    "common.waitingLocalService": "Naghihintay sa local Teale service sa PC na ito.",
    "common.noModelLoaded": "Walang naka-load na model",
    "common.syncing": "Nagsi-sync...",
    "footer.tagline": "teale - distributed ai inference para sa mundo",
    "auth.status.notConfigured": "Hindi naka-configure ang sign-in",
    "auth.status.notSignedIn": "Hindi naka-sign in",
    "auth.status.signedIn": "Naka-sign in",
    "auth.user.configure": "Magdagdag ng Supabase config sa node para ma-enable ang account sign-in.",
    "auth.user.prompt": "Gamitin ang GitHub, Google, o SMS para i-attach ang isang tao sa makinang ito.",
    "auth.note.walletStillWorks": "Gumagana pa rin ang wallet at supply sa pamamagitan ng Teale device auth.",
    "auth.note.claimsDevice": "Inaangkin ng phone, GitHub, o Google sign-in ang device na ito para sa isang account.",
    "auth.note.phoneCanLink": "Puwedeng i-link ang GitHub at Google sa phone account na ito.",
    "auth.note.allLinked": "Naka-link na sa account na ito ang phone, GitHub, at Google.",
    "auth.note.phoneLinkNotYet": "Hindi pa naka-enable ang phone linking sa existing account sa companion na ito.",
    "auth.button.signInGithub": "Mag-sign in gamit ang GitHub",
    "auth.button.signInGoogle": "Mag-sign in gamit ang Google",
    "auth.button.linkGithub": "I-link ang GitHub",
    "auth.button.linkGoogle": "I-link ang Google",
    "auth.button.githubLinked": "Naka-link ang GitHub",
    "auth.button.googleLinked": "Naka-link ang Google",
    "auth.button.signOut": "Mag-sign out",
    "auth.button.sendSms": "Magpadala ng SMS code",
    "auth.button.verifyCode": "I-verify ang code",
    "auth.alert.smsSent": "Naipadala ang SMS code.",
    "auth.error.enterPhone": "Maglagay muna ng phone number.",
    "auth.error.enterPhoneAndCode": "Ilagay ang phone number at SMS code.",
    "provider.github": "GitHub",
    "provider.google": "Google",
    "provider.phone": "phone",
    "provider.email": "email",
    "supply.status.loadingSelected": "Nilo-load ang napiling local model...",
    "supply.status.unloadingCurrent": "Inaalis ang kasalukuyang local model...",
    "model.action.loading": "Nilo-load",
    "model.action.unloading": "Inaalis",
    "model.action.servingNow": "Nagsi-serve na",
    "model.action.unavailable": "Hindi available",
    "model.action.loadAndSupply": "I-load at magsimulang mag-supply",
    "model.action.retryDownload": "Ulitin ang download",
    "model.action.downloadAndSupply": "I-download at magsimulang mag-supply",
    "model.action.loaded": "Na-load",
    "model.action.downloading": "Nagda-download",
    "model.action.busy": "Busy",
    "model.action.load": "I-load",
    "model.action.retry": "Ulitin",
    "model.action.download": "I-download",
    "account.wallet.note.summary": "I-sweep muna rito ang mga balanse ng device, tapos magpadala mula sa account wallet.",
    "account.wallet.note.pending": "Lalabas ang account wallet na ito kapag na-link na nang lokal ang device.",
    "account.wallet.note.signedOut": "Mag-sign in para i-link ang device na ito sa account wallet.",
    "account.devices.empty.signedOut": "Mag-sign in para makita ang mga device sa account na ito.",
    "account.devices.empty.none": "Wala pang nakitang linked devices.",
    "supply.recommended.none": "Walang natagpuang compatible na model",
    "supply.recommended.noneMeta": "Hindi pa pasok ang makinang ito sa Windows catalog ngayon.",
    "supply.recommended.waiting": "Naghihintay sa local Teale service...",
    "supply.recommended.waitingMeta": "Kapag sumagot na ang Teale nang lokal, irerekomenda nito ang pinakamainam na model para sa makinang ito.",
    "supply.models.noneYet": "Wala pang model data.",
    "supply.models.noneCompatible": "Wala pang compatible na model para sa device na ito.",
  },
};

function normalizeLanguage(candidate) {
  const value = String(candidate || "").toLowerCase();
  if (value.startsWith("zh")) {
    return "zh-Hans";
  }
  if (value.startsWith("pt")) {
    return "pt-BR";
  }
  if (value.startsWith("es")) {
    return "es";
  }
  if (value.startsWith("fil") || value.startsWith("tl")) {
    return "fil-PH";
  }
  return "en";
}

function loadInitialLanguage() {
  try {
    const saved = window.localStorage.getItem(LANGUAGE_STORAGE_KEY);
    if (saved && translations[saved]) {
      return saved;
    }
  } catch (_error) {}
  return normalizeLanguage(window.navigator.language);
}

let currentLanguage = loadInitialLanguage();

function t(key, params = {}) {
  const table = translations[currentLanguage] || translations.en;
  let value = table[key] || translations.en[key] || params.fallback || key;
  for (const [name, replacement] of Object.entries(params)) {
    if (name === "fallback") {
      continue;
    }
    value = value.replaceAll(`{{${name}}}`, String(replacement));
  }
  return value;
}

function viewDescription(view) {
  return t(`view.${view}.description`);
}

let activeView = "home";
let intervalHandle = null;
let lastSnapshot = null;
let supabaseClient = null;
let supabaseAuthKey = null;
let authSession = null;
let authUser = null;
let authIdentities = [];
let accountDevices = [];
let accountSummary = null;
let supabaseAccountDevices = [];
let linkedSupabaseUserId = null;
let linkedGatewayAccountUserId = null;
let pendingOAuthCallbackUrl = null;
let networkModels = [];
let networkModelsFetchedAt = 0;
let selectedNetworkModelId = null;
let demandSort = { key: "devices", dir: "desc" };
let pendingModelAction = null;

function apiUrl(path) {
  return `${API_BASE}${path}`;
}

function applyTranslations() {
  for (const element of document.querySelectorAll("[data-i18n]")) {
    element.textContent = t(element.dataset.i18n);
  }
  for (const element of document.querySelectorAll("[data-i18n-placeholder]")) {
    element.setAttribute("placeholder", t(element.dataset.i18nPlaceholder));
  }
  if (els.languageSelect) {
    els.languageSelect.value = currentLanguage;
  }
}

function setLanguage(language) {
  currentLanguage = translations[language] ? language : "en";
  try {
    window.localStorage.setItem(LANGUAGE_STORAGE_KEY, currentLanguage);
  } catch (_error) {}
  applyTranslations();
  setActiveView(activeView);
  if (lastSnapshot) {
    render(lastSnapshot);
  } else {
    renderAuthState();
    renderAccountWallet();
    renderAccountDevices();
  }
}

function providerDisplayName(provider) {
  return t(`provider.${provider}`);
}

function friendlyError(error) {
  const message = error?.message || "Unknown error";
  if (message === "Failed to fetch") {
    return t("common.waitingLocalService");
  }
  return message;
}

function hardwareRamGB(hardware) {
  return hardware?.total_ram_gb ?? hardware?.totalRAMGB ?? null;
}

function formatRamGB(value) {
  return typeof value === "number" ? `${Math.round(value)} GB` : "-";
}

function formatBytes(value) {
  if (typeof value !== "number" || Number.isNaN(value)) {
    return null;
  }
  if (value >= 1024 ** 3) {
    return `${(value / 1024 ** 3).toFixed(1)} GB`;
  }
  if (value >= 1024 ** 2) {
    return `${(value / 1024 ** 2).toFixed(1)} MB`;
  }
  if (value >= 1024) {
    return `${Math.round(value / 1024)} KB`;
  }
  return `${value} B`;
}

function formatCredits(value) {
  if (typeof value !== "number" || Number.isNaN(value)) {
    return "-";
  }
  return value.toLocaleString("en-US");
}

function formatUsdc(cents) {
  if (typeof cents !== "number" || Number.isNaN(cents)) {
    return "0.00";
  }
  return (cents / 100).toFixed(2);
}

function formatTimestamp(secs) {
  if (typeof secs !== "number") {
    return "-";
  }
  return new Date(secs * 1000).toLocaleString();
}

function formatRelativeFromUnix(secs) {
  if (typeof secs !== "number") {
    return "Not serving yet";
  }
  const diff = Math.max(0, Math.floor(Date.now() / 1000) - secs);
  if (diff < 60) {
    return "Just started";
  }
  if (diff < 3600) {
    return `${Math.floor(diff / 60)} min live`;
  }
  if (diff < 86400) {
    const hours = Math.floor(diff / 3600);
    const mins = Math.floor((diff % 3600) / 60);
    return `${hours}h ${mins}m live`;
  }
  const days = Math.floor(diff / 86400);
  const hours = Math.floor((diff % 86400) / 3600);
  return `${days}d ${hours}h live`;
}

function labelForState(state) {
  switch (state) {
    case "serving":
      return "Serving";
    case "downloading":
      return "Downloading";
    case "loading":
      return "Loading";
    case "paused_user":
      return "Paused";
    case "paused_battery":
      return "Waiting for AC";
    case "needs_model":
      return "Choose a model";
    case "starting":
      return "Starting";
    case "error":
      return "Error";
    default:
      return "Offline";
  }
}

function summarizeModelError(message) {
  if (!message) {
    return "";
  }
  if (message.includes("health check timed out")) {
    return "The model downloaded, but the backend needed more time to finish loading.";
  }
  return message.length > 220 ? `${message.slice(0, 217)}...` : message;
}

function asciiProgress(percent) {
  const cells = 20;
  const filled = Math.max(0, Math.min(cells, Math.round((percent / 100) * cells)));
  return `[${"█".repeat(filled)}${"░".repeat(cells - filled)}] ${percent}%`;
}

function maskToken(token) {
  if (!token) {
    return "Syncing...";
  }
  if (token.length <= 16) {
    return token;
  }
  return `${token.slice(0, 10)}...${token.slice(-6)}`;
}

function formatPricePerMillion(value) {
  const numeric = Number(value);
  if (!Number.isFinite(numeric)) {
    return "-";
  }
  const perMillion = numeric * 1_000_000;
  if (perMillion >= 1) {
    return `$${perMillion.toFixed(2)}`;
  }
  if (perMillion >= 0.01) {
    return `$${perMillion.toFixed(3)}`;
  }
  return `$${perMillion.toFixed(4)}`;
}

function formatContext(value) {
  return typeof value === "number" ? value.toLocaleString("en-US") : "-";
}

function formatMs(value) {
  return typeof value === "number" ? `${value} ms` : "-";
}

function formatTps(value) {
  return typeof value === "number" ? value.toFixed(1) : "-";
}

function shortModelLabel(id) {
  if (!id) {
    return "-";
  }
  const tail = id.split("/").pop() || id;
  return tail.replace(/-/g, " ");
}

function truncateDeviceId(value) {
  if (!value || value === "-") {
    return "-";
  }
  if (value.length <= 18) {
    return value;
  }
  return `${value.slice(0, 8)}...${value.slice(-8)}`;
}

function userLabel(user) {
  if (!user) {
    return t("auth.status.notSignedIn");
  }
  return user.phone || user.email || user.user_metadata?.user_name || user.id;
}

function providerLabel(identities) {
  if (!identities.length) {
    return t("auth.providers.none", { fallback: "No linked login methods yet." });
  }
  return identities.map((identity) => providerDisplayName(identity.provider)).join(" | ");
}

function availabilityRateLabel(wallet) {
  const tickCredits = wallet?.availability_credits_per_tick ?? 0;
  const tickSeconds = wallet?.availability_tick_seconds ?? 10;
  if (tickCredits > 0) {
    return `+${tickCredits} / ${tickSeconds} sec`;
  }
  const perMinute = wallet?.availability_rate_credits_per_minute ?? 0;
  if (perMinute > 0) {
    return `+${perMinute} / min`;
  }
  return t("wallet.rate.waiting", {
    fallback: "Availability credits begin once a compatible model is loaded and serving.",
  });
}

function walletStatusNote(wallet) {
  if (wallet?.gateway_sync_error) {
    return t("wallet.note.retrying", {
      fallback: "Credits are showing locally. Gateway sync is retrying in the background.",
    });
  }
  return t("wallet.note.live", {
    fallback: "Credits increase while supply is live. Network inference spends from this same balance.",
  });
}

function activeWalletBalance() {
  if (accountSummary) {
    return {
      credits: accountSummary.balance_credits ?? null,
      usdcCents: accountSummary.usdc_cents ?? 0,
      note: t("account.wallet.note.live", {
        fallback: "Account balance includes swept device balances. Local demand still uses this device bearer.",
      }),
      transactions: accountSummary.transactions || [],
    };
  }
  return {
    credits: lastSnapshot?.wallet?.gateway_balance_credits ?? null,
    usdcCents: lastSnapshot?.wallet?.gateway_usdc_cents ?? 0,
    note: walletStatusNote(lastSnapshot?.wallet),
    transactions: lastSnapshot?.wallet_transactions || [],
  };
}

function setBusyButton(button, label) {
  button.innerHTML = `<span class="action-content"><span class="spinner" aria-hidden="true"></span><span>${label}</span></span>`;
}

function clearBusyAction() {
  pendingModelAction = null;
}

function isPendingLoad(modelId) {
  return pendingModelAction?.kind === "load" && pendingModelAction.modelId === modelId;
}

function isPendingUnload() {
  return pendingModelAction?.kind === "unload";
}

function reconcilePendingAction(snapshot) {
  if (!pendingModelAction) {
    return;
  }

  if (pendingModelAction.kind === "load") {
    if (
      snapshot.loaded_model_id === pendingModelAction.modelId &&
      snapshot.service_state !== "loading"
    ) {
      clearBusyAction();
      return;
    }

    if (snapshot.service_state === "error") {
      clearBusyAction();
    }
    return;
  }

  if (!snapshot.loaded_model_id && snapshot.service_state !== "loading") {
    clearBusyAction();
    return;
  }

  if (snapshot.service_state === "error") {
    clearBusyAction();
  }
}

function currentNetworkModel() {
  return networkModels.find((model) => model.id === selectedNetworkModelId) || networkModels[0] || null;
}

function buildLocalCurl(demand) {
  if (!demand?.local_base_url || !demand?.local_model_id) {
    return "Waiting for a local model...";
  }
  return [
    `curl ${demand.local_base_url}/chat/completions \\`,
    `  -H "Content-Type: application/json" \\`,
    `  -d '{"model":"${demand.local_model_id}","messages":[{"role":"user","content":"hi"}]}'`,
  ].join("\n");
}

function buildNetworkCurl(demand, model) {
  if (!demand?.network_base_url || !demand?.network_bearer_token) {
    return "Waiting for a network bearer token...";
  }
  if (!model?.id) {
    return "Waiting for gateway models...";
  }
  return [
    `curl ${demand.network_base_url}/chat/completions \\`,
    `  -H "Authorization: Bearer ${demand.network_bearer_token}" \\`,
    `  -H "Content-Type: application/json" \\`,
    `  -d '{"model":"${model.id}","messages":[{"role":"user","content":"hi"}]}'`,
  ].join("\n");
}

function postNativeMessage(payload) {
  const message = JSON.stringify(payload);
  if (window.ipc?.postMessage) {
    window.ipc.postMessage(message);
    return true;
  }
  if (window.chrome?.webview?.postMessage) {
    window.chrome.webview.postMessage(message);
    return true;
  }
  return false;
}

async function copyText(text, label) {
  try {
    await navigator.clipboard.writeText(text);
    alert(`${label} copied.`);
  } catch (error) {
    alert(`Could not copy ${label.toLowerCase()}: ${error.message}`);
  }
}

async function copyTextQuiet(text) {
  await navigator.clipboard.writeText(text);
}

async function post(path, body = null) {
  const init = {
    method: "POST",
    headers: { "Content-Type": "application/json" },
  };
  if (body) {
    init.body = JSON.stringify(body);
  }
  const res = await fetch(apiUrl(path), init);
  if (!res.ok) {
    const payload = await res.json().catch(() => ({}));
    throw new Error(payload.error || `Request failed: ${res.status}`);
  }
  return res.json();
}

async function getJson(path) {
  const res = await fetch(apiUrl(path));
  if (!res.ok) {
    const payload = await res.json().catch(() => ({}));
    throw new Error(payload.error || `Request failed: ${res.status}`);
  }
  return res.json();
}

async function getJsonMaybeMissing(path) {
  const res = await fetch(apiUrl(path));
  if (res.status === 404) {
    return null;
  }
  if (!res.ok) {
    const payload = await res.json().catch(() => ({}));
    throw new Error(payload.error || `Request failed: ${res.status}`);
  }
  return res.json();
}

function setActiveView(view) {
  activeView = view;
  for (const button of els.viewButtons) {
    button.classList.toggle("active", button.dataset.viewButton === view);
  }
  for (const panel of els.views) {
    panel.classList.toggle("view-active", panel.dataset.view === view);
  }
  els.headerLine.textContent = viewDescription(view) || viewDescription("home");
  if (view === "demand") {
    refreshNetworkModels().catch((error) => {
      console.error("network models refresh failed", error);
    });
  }
}

function renderEmptyModels(message) {
  els.modelsList.innerHTML = "";
  const empty = document.createElement("div");
  empty.className = "empty-state";
  empty.textContent = message;
  els.modelsList.appendChild(empty);
}

function renderEmptyLedger(message) {
  els.ledgerList.innerHTML = "";
  const empty = document.createElement("div");
  empty.className = "empty-state";
  empty.textContent = message;
  els.ledgerList.appendChild(empty);
}

function renderEmptyDevices(message) {
  els.accountDevices.innerHTML = "";
  els.accountDevicesEmpty.textContent = message;
  els.accountDevicesEmpty.hidden = false;
}

function normalizeSupabaseTimestamp(value) {
  if (!value) {
    return null;
  }
  const millis = Date.parse(value);
  if (Number.isNaN(millis)) {
    return null;
  }
  return Math.floor(millis / 1000);
}

function setDisconnected(error) {
  els.statusChip.textContent = "Offline";
  els.statusLine.textContent = friendlyError(error);
  els.deviceName.textContent = "-";
  els.deviceRam.textContent = "-";
  els.deviceBackend.textContent = "-";
  els.devicePower.textContent = "-";
  els.currentModel.textContent = t("common.noModelLoaded");
  els.unloadButton.disabled = true;
  els.unloadButton.textContent = "Unload current model";
  els.recommendedName.textContent = t("supply.recommended.waiting");
  els.recommendedMeta.textContent = t("supply.recommended.waitingMeta");
  els.recommendedError.hidden = true;
  els.recommendedAction.textContent = t("model.action.unavailable");
  els.recommendedAction.disabled = true;
  els.transferPanel.hidden = true;
  renderEmptyModels(t("supply.models.noneYet"));

  els.homeStatus.textContent = "Offline";
  els.homeModel.textContent = t("common.noModelLoaded");
  els.homeBalance.textContent = t("common.waitingLocalService");
  els.homeAccount.textContent = userLabel(authUser);

  els.supplyEarningRate.textContent = "Waiting for a loaded model...";
  els.supplySessionCredits.textContent = "0";
  els.supplyWalletBalance.textContent = t("common.waitingLocalService");

  els.localBaseUrl.textContent = "-";
  els.localModelId.textContent = t("common.noModelLoaded");
  els.localCurl.textContent = "Waiting for a local model...";
  els.networkBaseUrl.textContent = "-";
  els.networkToken.textContent = t("common.syncing");
  els.networkSelectedModel.textContent = "Waiting for gateway models...";
  els.networkCurl.textContent = "Waiting for a network bearer token...";
  els.networkModelTableBody.innerHTML = "";
  els.networkModelEmpty.textContent = "The network model table appears once Teale responds locally.";

  els.walletBalance.textContent = t("common.waitingLocalService");
  els.walletUsdc.textContent = "0.00";
  els.walletSessionCredits.textContent = "0";
  els.walletCreditsToday.textContent = "0";
  els.walletEarned.textContent = "-";
  els.walletSpent.textContent = "-";
  els.walletRequests.textContent = "0";
  els.walletSince.textContent = "Not serving yet";
  els.walletRate.textContent = "Availability credits begin once a compatible model is loaded and serving.";
  els.walletNote.textContent = "The companion will sync wallet data once Teale responds locally.";
  renderEmptyLedger("No ledger entries yet.");
  els.accountWalletBalance.textContent = t("common.waitingLocalService");
  els.accountWalletUsdc.textContent = "0.00";
  els.accountWalletNote.textContent = t("account.wallet.note.signedOut");
}

function updateRecommendedAction(snapshot, recommended) {
  const activeTransfer = snapshot.active_transfer;
  if (!recommended) {
    els.recommendedName.textContent = t("supply.recommended.none");
    els.recommendedMeta.textContent = t("supply.recommended.noneMeta");
    els.recommendedError.hidden = true;
    els.recommendedAction.textContent = t("model.action.unavailable");
    els.recommendedAction.disabled = true;
    els.recommendedAction.onclick = null;
    return;
  }

  els.recommendedName.textContent = recommended.display_name;
  els.recommendedMeta.textContent = `${Math.round(recommended.required_ram_gb)} GB RAM minimum // ${recommended.size_gb.toFixed(1)} GB download`;
  els.recommendedError.textContent = summarizeModelError(recommended.last_error);
  els.recommendedError.hidden = !recommended.last_error;

  if (recommended.loaded && snapshot.service_state === "serving") {
    els.recommendedAction.textContent = t("model.action.servingNow");
    els.recommendedAction.disabled = true;
    els.recommendedAction.onclick = null;
    return;
  }

  if (isPendingLoad(recommended.id)) {
    setBusyButton(els.recommendedAction, t("model.action.loading"));
    els.recommendedAction.disabled = true;
    els.recommendedAction.onclick = null;
    return;
  }

  if (activeTransfer?.model_id === recommended.id) {
    const percent = activeTransfer.bytes_total
      ? Math.round((activeTransfer.bytes_downloaded / activeTransfer.bytes_total) * 100)
      : 0;
    els.recommendedAction.textContent = `Downloading ${percent}%`;
    els.recommendedAction.disabled = true;
    els.recommendedAction.onclick = null;
    return;
  }

  if (recommended.downloaded) {
    els.recommendedAction.textContent = t("model.action.loadAndSupply");
    els.recommendedAction.disabled = false;
    els.recommendedAction.onclick = async () => {
      try {
        pendingModelAction = { kind: "load", modelId: recommended.id };
        render(lastSnapshot);
        await post("/v1/app/models/load", { model: recommended.id });
        await refresh();
      } catch (error) {
        clearBusyAction();
        render(lastSnapshot);
        alert(error.message);
      }
    };
    return;
  }

  els.recommendedAction.textContent = recommended.last_error
    ? t("model.action.retryDownload")
    : t("model.action.downloadAndSupply");
  els.recommendedAction.disabled = Boolean(activeTransfer);
  els.recommendedAction.onclick = async () => {
    try {
      await post("/v1/app/models/download", { model: recommended.id });
      await refresh();
    } catch (error) {
      alert(error.message);
    }
  };
}

function renderTransfer(activeTransfer) {
  if (!activeTransfer) {
    els.transferPanel.hidden = true;
    return;
  }
  els.transferPanel.hidden = false;
  const percent = activeTransfer.bytes_total
    ? Math.round((activeTransfer.bytes_downloaded / activeTransfer.bytes_total) * 100)
    : 0;
  const details = [];
  if (activeTransfer.bytes_downloaded != null) {
    details.push(formatBytes(activeTransfer.bytes_downloaded));
  }
  if (activeTransfer.bytes_total != null) {
    details.push(`of ${formatBytes(activeTransfer.bytes_total)}`);
  }
  if (activeTransfer.bytes_per_sec != null) {
    details.push(`${formatBytes(activeTransfer.bytes_per_sec)}/s`);
  }
  if (activeTransfer.eta_seconds != null) {
    details.push(`ETA ${Math.max(1, Math.round(activeTransfer.eta_seconds / 60))} min`);
  }
  els.transferPercent.textContent = `${percent}%`;
  els.transferLabel.textContent = `${activeTransfer.model_id} // ${details.join(" // ")}`;
  els.transferBarText.textContent = asciiProgress(percent);
}

function renderModels(snapshot) {
  const models = snapshot.models || [];
  const activeTransfer = snapshot.active_transfer;
  els.modelsList.innerHTML = "";

  if (!models.length) {
    renderEmptyModels(t("supply.models.noneCompatible"));
    return;
  }

  for (const model of models) {
    const row = document.createElement("article");
    row.className = "model-row";

    const info = document.createElement("div");
    const title = document.createElement("h3");
    title.textContent = model.display_name;
    const meta = document.createElement("p");
    meta.className = "model-meta";
    meta.textContent = `demand #${model.demand_rank} // ${Math.round(model.required_ram_gb)} GB RAM // ${model.size_gb.toFixed(1)} GB`;
    const state = document.createElement("p");
    state.className = "model-state";
    const stateParts = [];
    if (model.recommended) {
      stateParts.push("recommended");
    }
    if (activeTransfer?.model_id === model.id) {
      const percent = activeTransfer.bytes_total
        ? Math.round((activeTransfer.bytes_downloaded / activeTransfer.bytes_total) * 100)
        : 0;
      stateParts.push(`downloading ${percent}%`);
    } else if (model.loaded) {
      stateParts.push("loaded");
    } else if (model.downloaded) {
      stateParts.push("downloaded");
    } else {
      stateParts.push("not downloaded");
    }
    state.textContent = stateParts.join(" // ");
    info.append(title, meta, state);

    if (model.last_error) {
      const error = document.createElement("p");
      error.className = "model-error";
      error.textContent = summarizeModelError(model.last_error);
      info.append(error);
    }

    const action = document.createElement("button");
    action.className = "action";
    if (model.loaded) {
      action.textContent = t("model.action.loaded");
      action.disabled = true;
    } else if (activeTransfer?.model_id === model.id) {
      action.textContent = t("model.action.downloading");
      action.disabled = true;
    } else if (isPendingLoad(model.id)) {
      setBusyButton(action, t("model.action.loading"));
      action.disabled = true;
    } else if (pendingModelAction) {
      action.textContent = t("model.action.busy");
      action.disabled = true;
    } else if (activeTransfer) {
      action.textContent = t("model.action.busy");
      action.disabled = true;
    } else if (model.downloaded) {
      action.textContent = t("model.action.load");
      action.onclick = async () => {
        try {
          pendingModelAction = { kind: "load", modelId: model.id };
          render(lastSnapshot);
          await post("/v1/app/models/load", { model: model.id });
          await refresh();
        } catch (error) {
          clearBusyAction();
          render(lastSnapshot);
          alert(error.message);
        }
      };
    } else {
      action.textContent = model.last_error ? t("model.action.retry") : t("model.action.download");
      action.onclick = async () => {
        try {
          await post("/v1/app/models/download", { model: model.id });
          await refresh();
        } catch (error) {
          alert(error.message);
        }
      };
    }

    row.append(info, action);
    els.modelsList.appendChild(row);
  }
}

function sortModels(rows) {
  const direction = demandSort.dir === "asc" ? 1 : -1;
  return rows.slice().sort((left, right) => {
    const key = demandSort.key;
    let a = key === "name" ? left.id : left[key];
    let b = key === "name" ? right.id : right[key];
    if (typeof a === "string" && typeof b === "string") {
      if (key === "prompt" || key === "completion") {
        a = Number(a);
        b = Number(b);
      } else {
        return a.localeCompare(b) * direction;
      }
    }
    if (typeof a === "number" && typeof b === "number") {
      return (a - b) * direction;
    }
    if (typeof a === "string" && typeof b === "string") {
      return a.localeCompare(b) * direction;
    }
    return direction * String(a ?? "").localeCompare(String(b ?? ""));
  });
}

function renderNetworkModels() {
  els.networkModelTableBody.innerHTML = "";
  if (!networkModels.length) {
    els.networkModelEmpty.textContent = "No live gateway model data yet.";
    return;
  }

  const sorted = sortModels(networkModels);
  if (!sorted.some((model) => model.id === selectedNetworkModelId)) {
    selectedNetworkModelId = sorted[0].id;
  }
  els.networkModelEmpty.textContent = `${sorted.length} live network models`;

  for (const model of sorted) {
    const tr = document.createElement("tr");
    if (model.id === selectedNetworkModelId) {
      tr.classList.add("is-selected");
    }
    tr.title = model.id;
    tr.addEventListener("click", () => {
      selectedNetworkModelId = model.id;
      renderNetworkModels();
      renderDemand(lastSnapshot);
    });

    const cells = [
      shortModelLabel(model.id),
      formatContext(model.context),
      String(model.devices),
      formatMs(model.ttft),
      formatTps(model.tps),
      formatPricePerMillion(model.prompt),
      formatPricePerMillion(model.completion),
    ];

    for (const value of cells) {
      const td = document.createElement("td");
      td.textContent = value;
      tr.append(td);
    }

    els.networkModelTableBody.appendChild(tr);
  }
}

function renderLedger(entries) {
  els.ledgerList.innerHTML = "";
  if (!entries?.length) {
    renderEmptyLedger("No ledger entries yet.");
    return;
  }

  for (const entry of entries) {
    const row = document.createElement("article");
    row.className = "ledger-row";

    const info = document.createElement("div");
    const title = document.createElement("h3");
    title.textContent = entry.type;
    const meta = document.createElement("p");
    meta.className = "ledger-meta";
    meta.textContent = [formatTimestamp(entry.timestamp), entry.device_id].filter(Boolean).join(" // ");
    info.append(title, meta);

    if (entry.note || entry.ref_request_id) {
      const note = document.createElement("p");
      note.className = "ledger-note";
      note.textContent = [entry.note, entry.ref_request_id].filter(Boolean).join(" // ");
      info.append(note);
    }

    const amount = document.createElement("div");
    amount.className = entry.amount < 0 ? "amount-negative" : "amount-positive";
    amount.textContent = `${entry.amount < 0 ? "" : "+"}${formatCredits(entry.amount)}`;

    row.append(info, amount);
    els.ledgerList.appendChild(row);
  }
}

function renderAccountWallet() {
  if (accountSummary) {
    els.accountWalletBalance.textContent = formatCredits(accountSummary.balance_credits ?? 0);
    els.accountWalletUsdc.textContent = formatUsdc(accountSummary.usdc_cents ?? 0);
    els.accountWalletNote.textContent = t("account.wallet.note.summary");
    return;
  }

  if (authUser) {
    els.accountWalletBalance.textContent = t("common.syncing");
    els.accountWalletUsdc.textContent = "0.00";
    els.accountWalletNote.textContent = t("account.wallet.note.pending");
    return;
  }

  els.accountWalletBalance.textContent = "-";
  els.accountWalletUsdc.textContent = "0.00";
  els.accountWalletNote.textContent = t("account.wallet.note.signedOut");
}

function buildAccountDeviceRows() {
  const rows = new Map();
  const currentDeviceId = lastSnapshot?.wallet?.current_device_id || null;
  const summaryDevices = accountSummary?.devices || [];

  for (const device of summaryDevices) {
    rows.set(device.device_id, {
      key: device.device_id,
      label: device.device_name || "Unknown device",
      deviceId: device.device_id,
      walletBalance: device.wallet_balance_credits ?? 0,
      current: currentDeviceId === device.device_id,
      localOnly: false,
      removable: currentDeviceId !== device.device_id,
      sweepEnabled: (device.wallet_balance_credits ?? 0) > 0,
      sourceRowId: device.device_id,
      lastSeen: device.last_seen ?? 0,
    });
  }

  for (const device of supabaseAccountDevices) {
    const deviceId = device.wan_node_id || device.id || "-";
    const key = device.wan_node_id || `supabase:${device.id}`;
    const existing = rows.get(deviceId) || rows.get(key);
    if (existing) {
      existing.label = existing.label === "Unknown device" && device.device_name
        ? device.device_name
        : existing.label;
      existing.lastSeen = Math.max(existing.lastSeen || 0, normalizeSupabaseTimestamp(device.last_seen) || 0);
      continue;
    }

    rows.set(key, {
      key,
      label: device.device_name || "Unknown device",
      deviceId,
      walletBalance: null,
      current: currentDeviceId === deviceId,
      localOnly: false,
      removable: currentDeviceId !== deviceId,
      sweepEnabled: false,
      sourceRowId: device.id,
      lastSeen: normalizeSupabaseTimestamp(device.last_seen) || 0,
    });
  }

  if (lastSnapshot?.device?.display_name && currentDeviceId && !rows.has(currentDeviceId)) {
    rows.set(currentDeviceId, {
      key: currentDeviceId,
      label: lastSnapshot.device.display_name,
      deviceId: currentDeviceId,
      walletBalance: lastSnapshot.wallet?.gateway_balance_credits ?? null,
      current: true,
      localOnly: true,
      removable: false,
      sweepEnabled: false,
      sourceRowId: currentDeviceId,
      lastSeen: Math.floor(Date.now() / 1000),
    });
  }

  return Array.from(rows.values()).sort((left, right) => {
    if (left.current !== right.current) {
      return left.current ? -1 : 1;
    }
    return (right.lastSeen || 0) - (left.lastSeen || 0);
  });
}

function renderAccountDevices() {
  els.accountDevices.innerHTML = "";
  if (!authUser && !lastSnapshot?.device?.display_name) {
    renderEmptyDevices(t("account.devices.empty.signedOut"));
    return;
  }

  const rows = buildAccountDeviceRows();
  if (!rows.length) {
    renderEmptyDevices(t("account.devices.empty.none"));
    return;
  }
  els.accountDevicesEmpty.hidden = true;

  for (const device of rows) {
    const tr = document.createElement("tr");

    const labelCell = document.createElement("td");
    labelCell.textContent = device.label;
    if (device.current) {
      const badge = document.createElement("span");
      badge.className = "device-badge";
      badge.textContent = t("account.device.this", { fallback: "this device" });
      labelCell.append(" ");
      labelCell.append(badge);
    } else if (device.localOnly) {
      const badge = document.createElement("span");
      badge.className = "device-badge";
      badge.textContent = t("account.device.local", { fallback: "local" });
      labelCell.append(" ");
      labelCell.append(badge);
    }

    const idCell = document.createElement("td");
    const idButton = document.createElement("button");
    idButton.type = "button";
    idButton.className = "device-id-button";
    idButton.textContent = truncateDeviceId(device.deviceId);
    idButton.title = device.deviceId || "-";
    idButton.addEventListener("click", async () => {
      if (!device.deviceId || device.deviceId === "-") {
        return;
      }
      try {
        const original = idButton.textContent;
        await copyTextQuiet(device.deviceId);
        idButton.textContent = t("common.copied", { fallback: "copied" });
        window.setTimeout(() => {
          idButton.textContent = original;
        }, 900);
      } catch (error) {
        alert(`Could not copy device id: ${error.message}`);
      }
    });
    idCell.append(idButton);

    const walletCell = document.createElement("td");
    walletCell.textContent = typeof device.walletBalance === "number"
      ? `${formatCredits(device.walletBalance)} credits`
      : "-";

    const actionCell = document.createElement("td");
    const actionRow = document.createElement("div");
    actionRow.className = "actions actions-tight";

    const sweep = document.createElement("button");
    sweep.className = "action";
    sweep.textContent = t("account.device.sweep", { fallback: "Sweep" });
    sweep.disabled = !authUser || !device.sweepEnabled;
    sweep.addEventListener("click", async () => {
      try {
        const result = await post("/v1/app/account/sweep", { deviceID: device.deviceId });
        accountSummary = result.account || accountSummary;
        await refresh();
        await refreshAccountState();
        render(lastSnapshot);
      } catch (error) {
        alert(error.message);
      }
    });
    actionRow.append(sweep);

    if (device.removable && device.sourceRowId) {
      const remove = document.createElement("button");
      remove.className = "action";
      remove.textContent = t("account.device.remove", { fallback: "Remove" });
      remove.addEventListener("click", async () => {
        if (!confirm(`Remove ${device.label} from this account?`)) {
          return;
        }
        try {
          await post("/v1/app/account/devices/remove", { deviceID: device.deviceId });
          await markSupabaseDeviceInactive(device.deviceId);
          await refreshAccountState();
          renderAccountDevices();
        } catch (error) {
          alert(error.message);
        }
      });
      actionRow.append(remove);
    }

    actionCell.append(actionRow);
    tr.append(labelCell, idCell, walletCell, actionCell);
    els.accountDevices.appendChild(tr);
  }
}

function renderAuthState() {
  const githubIdentity = authIdentities.find((identity) => identity.provider === "github");
  const googleIdentity = authIdentities.find((identity) => identity.provider === "google");
  const phoneIdentity = authIdentities.find((identity) => identity.provider === "phone");

  els.accountId.textContent = authUser?.id || "-";
  els.accountEmail.textContent = authUser?.email || "-";
  els.accountPhone.textContent = authUser?.phone || "-";
  els.accountIdentities.textContent = providerLabel(authIdentities);
  els.authPhoneSendButton.textContent = t("auth.button.sendSms");
  els.authPhoneVerifyButton.textContent = t("auth.button.verifyCode");
  els.authSignoutButton.textContent = t("auth.button.signOut");

  if (!lastSnapshot?.auth?.configured) {
    els.authStatus.textContent = t("auth.status.notConfigured");
    els.authUser.textContent = t("auth.user.configure");
    els.authGithubButton.disabled = true;
    els.authGoogleButton.disabled = true;
    els.authPhoneSendButton.disabled = true;
    els.authPhoneVerifyButton.disabled = true;
    els.authSignoutButton.hidden = true;
    els.authPhonePanel.hidden = false;
    els.authNote.textContent = t("auth.note.walletStillWorks");
    return;
  }

  if (!authUser) {
    els.authStatus.textContent = t("auth.status.notSignedIn");
    els.authUser.textContent = t("auth.user.prompt");
    els.authGithubButton.textContent = t("auth.button.signInGithub");
    els.authGithubButton.disabled = false;
    els.authGoogleButton.textContent = t("auth.button.signInGoogle");
    els.authGoogleButton.disabled = false;
    els.authPhonePanel.hidden = false;
    els.authPhoneSendButton.disabled = false;
    els.authPhoneVerifyButton.disabled = false;
    els.authSignoutButton.hidden = true;
    els.authNote.textContent = t("auth.note.claimsDevice");
    return;
  }

  els.authStatus.textContent = t("auth.status.signedIn");
  els.authUser.textContent = userLabel(authUser);
  els.authSignoutButton.hidden = false;

  if (githubIdentity) {
    els.authGithubButton.textContent = t("auth.button.githubLinked");
    els.authGithubButton.disabled = true;
  } else {
    els.authGithubButton.textContent = t("auth.button.linkGithub");
    els.authGithubButton.disabled = false;
  }

  if (googleIdentity) {
    els.authGoogleButton.textContent = t("auth.button.googleLinked");
    els.authGoogleButton.disabled = true;
  } else {
    els.authGoogleButton.textContent = t("auth.button.linkGoogle");
    els.authGoogleButton.disabled = false;
  }

  if (phoneIdentity) {
    els.authPhonePanel.hidden = true;
    els.authNote.textContent = githubIdentity && googleIdentity
      ? t("auth.note.allLinked")
      : t("auth.note.phoneCanLink");
  } else {
    els.authPhonePanel.hidden = true;
    els.authNote.textContent = t("auth.note.phoneLinkNotYet");
  }
}

async function ensureAuthClient(authConfig) {
  if (!authConfig?.configured) {
    supabaseClient = null;
    supabaseAuthKey = null;
    authSession = null;
    authUser = null;
    authIdentities = [];
    linkedSupabaseUserId = null;
    linkedGatewayAccountUserId = null;
    accountDevices = [];
    accountSummary = null;
    supabaseAccountDevices = [];
    renderAuthState();
    renderAccountDevices();
    return;
  }

  const configKey = `${authConfig.supabase_url}|${authConfig.supabase_anon_key}|${authConfig.redirect_url}`;
  if (supabaseClient && supabaseAuthKey === configKey) {
    return;
  }

  if (!window.supabase?.createClient) {
    els.authStatus.textContent = "Supabase client failed to load";
    els.authUser.textContent = "Check network access to the Supabase CDN script.";
    return;
  }

  supabaseAuthKey = configKey;
  supabaseClient = window.supabase.createClient(authConfig.supabase_url, authConfig.supabase_anon_key, {
    auth: {
      persistSession: true,
      autoRefreshToken: true,
      detectSessionInUrl: false,
    },
  });

  supabaseClient.auth.onAuthStateChange(async (_event, session) => {
    authSession = session;
    authUser = session?.user || null;
    linkedSupabaseUserId = authUser ? linkedSupabaseUserId : null;
    linkedGatewayAccountUserId = authUser ? linkedGatewayAccountUserId : null;
    await ensureSupabaseIdentity();
    await ensureGatewayAccountLink();
    await refreshAccountState();
    renderAccountWallet();
    renderAuthState();
    renderAccountDevices();
    renderHome(lastSnapshot);
  });

  const { data } = await supabaseClient.auth.getSession();
  authSession = data.session;
  authUser = data.session?.user || null;
  await consumePendingOAuthCallback();
  await ensureSupabaseIdentity();
  await ensureGatewayAccountLink();
  await refreshAccountState();
  renderAccountWallet();
  renderAuthState();
  renderAccountDevices();
}

async function refreshAccountState() {
  if (!supabaseClient || !authUser) {
    authIdentities = [];
    accountDevices = [];
    accountSummary = null;
    supabaseAccountDevices = [];
    return;
  }

  const [{ data: identitiesData }, devicesResult, summary] = await Promise.all([
    supabaseClient.auth.getUserIdentities(),
    supabaseClient
      .from("devices")
      .select("id,user_id,device_name,platform,chip_name,ram_gb,wan_node_id,registered_at,last_seen,is_active")
      .eq("user_id", authUser.id)
      .order("last_seen", { ascending: false }),
    getJsonMaybeMissing("/v1/app/account").catch((error) => {
      console.warn("account summary fetch failed", error);
      return null;
    }),
  ]);

  authIdentities = identitiesData?.identities || authUser.identities || [];
  accountSummary = summary;
  accountDevices = summary?.devices || [];
  supabaseAccountDevices = devicesResult?.data || [];
}

async function consumePendingOAuthCallback() {
  if (!pendingOAuthCallbackUrl || !supabaseClient) {
    return;
  }
  const url = new URL(pendingOAuthCallbackUrl);
  const oauthError = url.searchParams.get("error_description") || url.searchParams.get("error");
  if (oauthError) {
    els.authStatus.textContent = "Sign-in failed";
    els.authUser.textContent = oauthError;
    pendingOAuthCallbackUrl = null;
    return;
  }
  const code = url.searchParams.get("code");
  if (!code) {
    pendingOAuthCallbackUrl = null;
    return;
  }
  try {
    const { data, error } = await supabaseClient.auth.exchangeCodeForSession(code);
    if (error) {
      throw error;
    }
    authSession = data.session;
    authUser = data.session?.user || null;
    pendingOAuthCallbackUrl = null;
    window.history.replaceState({}, "", "teale://localhost/");
  } catch (error) {
    els.authStatus.textContent = "Sign-in failed";
    els.authUser.textContent = error.message;
    pendingOAuthCallbackUrl = null;
  }
}

async function ensureSupabaseIdentity() {
  if (!supabaseClient || !authUser || !lastSnapshot?.device) {
    return;
  }
  if (linkedSupabaseUserId === authUser.id) {
    return;
  }

  const metadata = authUser.user_metadata || {};
  const displayName = metadata.user_name || metadata.full_name || metadata.name || authUser.email || authUser.phone || null;
  const profilePayload = {
    id: authUser.id,
    display_name: displayName,
    phone: authUser.phone || null,
    email: authUser.email || null,
  };

  const { error: profileError } = await supabaseClient.from("profiles").upsert(profilePayload, { onConflict: "id" });
  if (profileError) {
    throw profileError;
  }

  const device = lastSnapshot.device || {};
  const hardware = device.hardware || {};
  const deviceName = device.display_name || "Windows device";
  const ramGb = hardwareRamGB(hardware);
  const chipName = hardware.chipName || hardware.chip_name || hardware.cpu_name || hardware.chipFamily || null;

  const currentDeviceId = lastSnapshot?.wallet?.current_device_id || null;
  let existingDevices;
  let existingError;

  if (currentDeviceId) {
    const result = await supabaseClient
      .from("devices")
      .select("id,wan_node_id")
      .eq("user_id", authUser.id)
      .eq("wan_node_id", currentDeviceId)
      .eq("is_active", true)
      .order("last_seen", { ascending: false })
      .limit(1);
    existingDevices = result.data;
    existingError = result.error;
  }

  if (!existingDevices?.length && !existingError) {
    const fallback = await supabaseClient
      .from("devices")
      .select("id,wan_node_id")
      .eq("user_id", authUser.id)
      .eq("device_name", deviceName)
      .eq("platform", "windows")
      .eq("is_active", true)
      .order("last_seen", { ascending: false })
      .limit(1);
    existingDevices = fallback.data;
    existingError = fallback.error;
  }

  if (existingError) {
    console.warn("Supabase device lookup failed", existingError);
    linkedSupabaseUserId = authUser.id;
    return;
  }

  const payload = {
    user_id: authUser.id,
    device_name: deviceName,
    platform: "windows",
    chip_name: chipName,
    ram_gb: typeof ramGb === "number" ? Math.round(ramGb) : null,
    wan_node_id: currentDeviceId,
    is_active: true,
    last_seen: new Date().toISOString(),
  };

  if (existingDevices?.length) {
    const { error } = await supabaseClient.from("devices").update(payload).eq("id", existingDevices[0].id);
    if (error) {
      console.warn("Supabase device update failed", error);
    }
  } else {
    const { error } = await supabaseClient.from("devices").insert(payload);
    if (error) {
      console.warn("Supabase device insert failed", error);
    }
  }

  linkedSupabaseUserId = authUser.id;
}

async function ensureGatewayAccountLink() {
  if (!authUser || !lastSnapshot?.wallet?.current_device_id) {
    return;
  }
  if (linkedGatewayAccountUserId === authUser.id) {
    return;
  }

  const githubIdentity = (authUser.identities || []).find((identity) => identity.provider === "github");
  const metadata = authUser.user_metadata || {};
  const payload = {
    accountUserID: authUser.id,
    displayName: metadata.user_name || metadata.full_name || metadata.name || null,
    phone: authUser.phone || null,
    email: authUser.email || null,
    githubUsername: metadata.user_name || githubIdentity?.identity_data?.user_name || null,
  };

  try {
    accountSummary = await post("/v1/app/account/link", payload);
    linkedGatewayAccountUserId = authUser.id;
  } catch (error) {
    console.warn("gateway account link failed", error);
  }
}

async function markSupabaseDeviceInactive(deviceId) {
  if (!supabaseClient || !authUser || !deviceId) {
    return;
  }
  try {
    const { error } = await supabaseClient
      .from("devices")
      .update({ is_active: false })
      .eq("user_id", authUser.id)
      .eq("wan_node_id", deviceId);
    if (error) {
      throw error;
    }
  } catch (error) {
    console.warn("supabase device deactivate failed", error);
  }
}

async function startOAuth(provider) {
  if (!supabaseClient || !lastSnapshot?.auth?.configured) {
    return;
  }
  try {
    let response;
    if (authUser) {
      response = await supabaseClient.auth.linkIdentity({
        provider,
        options: {
          redirectTo: lastSnapshot.auth.redirect_url,
          skipBrowserRedirect: true,
        },
      });
    } else {
      response = await supabaseClient.auth.signInWithOAuth({
        provider,
        options: {
          redirectTo: lastSnapshot.auth.redirect_url,
          skipBrowserRedirect: true,
        },
      });
    }

    if (response.error) {
      throw response.error;
    }
    if (!response.data?.url) {
      throw new Error(`${providerDisplayName(provider)} sign-in URL was not returned.`);
    }
    if (!postNativeMessage({ type: "openExternal", url: response.data.url })) {
      window.open(response.data.url, "_blank", "noopener,noreferrer");
    }
  } catch (error) {
    alert(error.message);
  }
}

async function refreshNetworkModels(force = false) {
  if (!lastSnapshot) {
    return;
  }
  const now = Date.now();
  if (!force && now - networkModelsFetchedAt < 10_000) {
    return;
  }
  try {
    const models = await getJson("/v1/app/network/models");
    networkModels = models.map((model) => ({
      id: model.id,
      context: model.context_length,
      devices: model.device_count,
      ttft: model.ttft_ms_p50,
      tps: model.tps_p50,
      prompt: model.pricing_prompt,
      completion: model.pricing_completion,
    }));
    networkModelsFetchedAt = now;
    renderNetworkModels();
    renderDemand(lastSnapshot);
  } catch (error) {
    console.error(error);
    networkModels = [];
    els.networkModelTableBody.innerHTML = "";
    els.networkModelEmpty.textContent = "Could not load live gateway models yet.";
  }
}

function renderHome(snapshot) {
  const walletView = activeWalletBalance();
  els.homeStatus.textContent = labelForState(snapshot?.service_state);
  els.homeModel.textContent = snapshot?.loaded_model_id || "No model loaded";
  els.homeBalance.textContent = walletView.credits != null
    ? `${formatCredits(walletView.credits)} credits`
    : "Syncing...";
  els.homeAccount.textContent = userLabel(authUser);
}

function renderSupply(snapshot) {
  const device = snapshot.device || {};
  const hardware = device.hardware || {};
  const wallet = snapshot.wallet || {};
  const modelActionBusy = Boolean(pendingModelAction);

  els.statusChip.textContent = labelForState(snapshot.service_state);
  if (isPendingUnload()) {
    els.statusLine.textContent = t("supply.status.unloadingCurrent");
  } else if (pendingModelAction?.kind === "load") {
    els.statusLine.textContent = t("supply.status.loadingSelected");
  } else {
    els.statusLine.textContent = snapshot.state_reason || "Teale is ready locally.";
  }
  els.deviceName.textContent = device.display_name || "-";
  els.deviceRam.textContent = formatRamGB(hardwareRamGB(hardware));
  els.deviceBackend.textContent = device.gpu_backend || hardware.gpu_backend || hardware.gpuBackend || "-";
  els.devicePower.textContent = device.on_ac ? "Plugged in" : "Battery";
  els.currentModel.textContent = snapshot.loaded_model_id || t("common.noModelLoaded");
  if (isPendingUnload()) {
    setBusyButton(els.unloadButton, t("model.action.unloading"));
    els.unloadButton.disabled = true;
  } else {
    els.unloadButton.textContent = t("model.action.unloadCurrent", { fallback: "Unload current model" });
    els.unloadButton.disabled = !snapshot.loaded_model_id || modelActionBusy;
  }

  els.supplyEarningRate.textContent = availabilityRateLabel(wallet);
  els.supplySessionCredits.textContent = formatCredits(wallet.estimated_session_credits ?? 0);
  els.supplyWalletBalance.textContent = activeWalletBalance().credits != null
    ? `${formatCredits(activeWalletBalance().credits)} credits`
    : "Syncing...";

  const recommended = snapshot.models.find((model) => model.recommended) || snapshot.models[0];
  updateRecommendedAction(snapshot, recommended);
  renderTransfer(snapshot.active_transfer);
  renderModels(snapshot);
}

function renderDemand(snapshot) {
  const demand = snapshot.demand || {};
  const selected = currentNetworkModel();

  els.localBaseUrl.textContent = demand.local_base_url || "-";
  els.localModelId.textContent = demand.local_model_id || t("common.noModelLoaded");
  els.localCurl.textContent = buildLocalCurl(demand);

  els.networkBaseUrl.textContent = demand.network_base_url || "-";
  els.networkToken.textContent = maskToken(demand.network_bearer_token);
  els.networkTokenNote.textContent = demand.network_bearer_token
      ? "Use this bearer against gateway.teale.com. Requests spend from Teale credits."
      : "Waiting for the device bearer token from the gateway wallet sync.";
  els.networkSelectedModel.textContent = selected ? selected.id : t("demand.selected.waiting", { fallback: "Waiting for gateway models..." });
  els.networkCurl.textContent = buildNetworkCurl(demand, selected);
  renderNetworkModels();
}

function renderWallet(snapshot) {
  const walletView = activeWalletBalance();
  const wallet = snapshot.wallet || {};
  els.walletBalance.textContent = walletView.credits != null
    ? formatCredits(walletView.credits)
    : wallet.gateway_sync_error
      ? "Retrying sync"
      : "Syncing...";
  els.walletUsdc.textContent = formatUsdc(walletView.usdcCents ?? 0);
  els.walletSessionCredits.textContent = formatCredits(wallet.estimated_session_credits ?? 0);
  els.walletCreditsToday.textContent = formatCredits(wallet.credits_today ?? 0);
  els.walletEarned.textContent = wallet.gateway_total_earned_credits != null
    ? formatCredits(wallet.gateway_total_earned_credits)
    : "-";
  els.walletSpent.textContent = wallet.gateway_total_spent_credits != null
    ? formatCredits(wallet.gateway_total_spent_credits)
    : "-";
  els.walletRequests.textContent = formatCredits(wallet.completed_requests ?? 0);
  els.walletSince.textContent = formatRelativeFromUnix(wallet.supplying_since);
  els.walletRate.textContent = availabilityRateLabel(wallet);
  els.walletNote.textContent = walletView.note;
  renderLedger(walletView.transactions);
}

function render(snapshot) {
  lastSnapshot = snapshot;
  renderHome(snapshot);
  renderSupply(snapshot);
  renderDemand(snapshot);
  renderWallet(snapshot);
  renderAccountWallet();
  renderAuthState();
  renderAccountDevices();
}

async function refresh() {
  const res = await fetch(apiUrl("/v1/app"));
  if (!res.ok) {
    throw new Error(`Teale status failed: ${res.status}`);
  }
  const snapshot = await res.json();
  reconcilePendingAction(snapshot);
  lastSnapshot = snapshot;
  await ensureAuthClient(snapshot.auth);
  render(snapshot);
  if (activeView === "demand") {
    await refreshNetworkModels();
  }
}

function startPolling() {
  if (intervalHandle) {
    clearInterval(intervalHandle);
  }
  const everyMs = document.hidden ? 5000 : 1000;
  intervalHandle = setInterval(() => {
    refresh().catch((error) => setDisconnected(error));
  }, everyMs);
}

function exportLedgerCsv(entries) {
  if (!entries?.length) {
    alert("No ledger entries to export.");
    return;
  }
  const lines = [
    ["id", "type", "amount", "timestamp", "device_id", "ref_request_id", "note"].join(","),
    ...entries.map((entry) => [
      entry.id,
      entry.type,
      entry.amount,
      entry.timestamp,
      JSON.stringify(entry.device_id ?? ""),
      JSON.stringify(entry.ref_request_id ?? ""),
      JSON.stringify(entry.note ?? ""),
    ].join(",")),
  ];
  const blob = new Blob([lines.join("\n")], { type: "text/csv;charset=utf-8" });
  const link = document.createElement("a");
  link.href = URL.createObjectURL(blob);
  link.download = `teale-ledger-${new Date().toISOString().slice(0, 19).replace(/[:T]/g, "-")}.csv`;
  document.body.append(link);
  link.click();
  link.remove();
  URL.revokeObjectURL(link.href);
}

els.unloadButton.addEventListener("click", async () => {
  try {
    pendingModelAction = { kind: "unload" };
    render(lastSnapshot);
    await post("/v1/app/models/unload");
    await refresh();
  } catch (error) {
    clearBusyAction();
    render(lastSnapshot);
    alert(error.message);
  }
});

els.supplyWalletLink.addEventListener("click", () => setActiveView("wallet"));
els.homeOpenSupply.addEventListener("click", () => setActiveView("supply"));
els.homeOpenDemand.addEventListener("click", () => setActiveView("demand"));
els.homeOpenWallet.addEventListener("click", () => setActiveView("wallet"));
els.homeOpenAccount.addEventListener("click", () => setActiveView("account"));

els.authGithubButton.addEventListener("click", () => startOAuth("github"));
els.authGoogleButton.addEventListener("click", () => startOAuth("google"));

els.authPhoneSendButton.addEventListener("click", async () => {
  if (!supabaseClient || authUser) {
    return;
  }
  try {
    const phone = els.authPhoneInput.value.trim();
    if (!phone) {
      throw new Error(t("auth.error.enterPhone"));
    }
    const { error } = await supabaseClient.auth.signInWithOtp({ phone });
    if (error) {
      throw error;
    }
    alert(t("auth.alert.smsSent"));
  } catch (error) {
    alert(error.message);
  }
});

els.authPhoneVerifyButton.addEventListener("click", async () => {
  if (!supabaseClient || authUser) {
    return;
  }
  try {
    const phone = els.authPhoneInput.value.trim();
    const token = els.authPhoneCodeInput.value.trim();
    if (!phone || !token) {
      throw new Error(t("auth.error.enterPhoneAndCode"));
    }
    const { data, error } = await supabaseClient.auth.verifyOtp({ phone, token, type: "sms" });
    if (error) {
      throw error;
    }
    authSession = data.session;
    authUser = data.user;
    await ensureSupabaseIdentity();
    await ensureGatewayAccountLink();
    await refreshAccountState();
    renderAccountWallet();
    renderAuthState();
    renderAccountDevices();
    renderHome(lastSnapshot);
  } catch (error) {
    alert(error.message);
  }
});

els.authSignoutButton.addEventListener("click", async () => {
  if (!supabaseClient) {
    return;
  }
  try {
    const { error } = await supabaseClient.auth.signOut();
    if (error) {
      throw error;
    }
    authSession = null;
    authUser = null;
    authIdentities = [];
    linkedSupabaseUserId = null;
    linkedGatewayAccountUserId = null;
    accountDevices = [];
    accountSummary = null;
    supabaseAccountDevices = [];
    renderAccountWallet();
    renderAuthState();
    renderAccountDevices();
    renderHome(lastSnapshot);
  } catch (error) {
    alert(error.message);
  }
});

els.localCurlCopy.addEventListener("click", async () => {
  await copyText(els.localCurl.textContent, "Local curl");
});

els.networkTokenCopy.addEventListener("click", async () => {
  await copyText(lastSnapshot?.demand?.network_bearer_token || "", "Bearer token");
});

els.networkCurlCopy.addEventListener("click", async () => {
  await copyText(els.networkCurl.textContent, "Network curl");
});

els.ledgerExport.addEventListener("click", () => {
  exportLedgerCsv(activeWalletBalance().transactions || []);
});

els.sendSubmit.addEventListener("click", () => {
  alert("Transfers are not wired in this Windows companion yet.");
});

els.accountSendSubmit.addEventListener("click", () => {
  alert("Account wallet transfers are not wired in this Windows companion yet.");
});

for (const button of els.viewButtons) {
  button.addEventListener("click", () => setActiveView(button.dataset.viewButton));
}

els.languageSelect.addEventListener("change", (event) => {
  setLanguage(event.target.value);
});

for (const button of els.networkModelSortButtons) {
  button.addEventListener("click", async () => {
    const key = button.dataset.modelSort;
    if (demandSort.key === key) {
      demandSort.dir = demandSort.dir === "asc" ? "desc" : "asc";
    } else {
      demandSort.key = key;
      demandSort.dir = key === "name" ? "asc" : "desc";
    }
    renderNetworkModels();
    renderDemand(lastSnapshot);
  });
}

document.addEventListener("visibilitychange", startPolling);
window.__tealeHandleOAuthCallback = async (url) => {
  pendingOAuthCallbackUrl = url;
  await consumePendingOAuthCallback();
  await ensureGatewayAccountLink();
  await refreshAccountState();
  renderAccountWallet();
  renderAuthState();
  renderAccountDevices();
  renderHome(lastSnapshot);
};

applyTranslations();
setActiveView("home");
refresh().catch((error) => setDisconnected(error));
startPolling();
