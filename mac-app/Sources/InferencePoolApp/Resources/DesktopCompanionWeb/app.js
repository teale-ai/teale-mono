const DESKTOP_CONFIG = window.__TEALE_DESKTOP_CONFIG__ || {};
const API_BASE = DESKTOP_CONFIG.apiBase || "http://127.0.0.1:11437";
const ROUTES = {
  snapshot: "/v1/app",
  privacyFilterMode: "/v1/app/privacy-filter/mode",
  chatCompletions: "/v1/app/chat/completions",
  modelLoad: "/v1/app/models/load",
  modelDownload: "/v1/app/models/download",
  modelUnload: "/v1/app/models/unload",
  authSession: "/v1/app/auth/session",
  accountSummary: "/v1/app/account",
  accountApiKeys: "/v1/app/account/api-keys",
  accountApiKeysRevoke: "/v1/app/account/api-keys/revoke",
  accountLink: "/v1/app/account/link",
  accountSweep: "/v1/app/account/sweep",
  accountSend: "/v1/app/account/send",
  accountDevicesRemove: "/v1/app/account/devices/remove",
  networkModels: "/v1/app/network/models",
  networkStats: "/v1/app/network/stats",
  walletRefresh: "/v1/app/wallet/refresh",
  walletSend: "/v1/app/wallet/send",
  authPending: "teale://localhost/auth/pending",
  bundledApp: null,
  localApiKey: null,
  ...DESKTOP_CONFIG.routes,
};
const DESKTOP_PLATFORM = DESKTOP_CONFIG.platform || "windows";
const CHAT_TRANSPORT = DESKTOP_CONFIG.chatTransport || "app-proxy";
const DESKTOP_DEVICE_LABEL = DESKTOP_CONFIG.deviceLabel
  || `${DESKTOP_PLATFORM.charAt(0).toUpperCase()}${DESKTOP_PLATFORM.slice(1)} device`;
const SHELL_MODE = DESKTOP_CONFIG.shellMode === true;

const els = {
  headerLine: document.getElementById("header-line"),
  settingsMenu: document.getElementById("settings-menu"),
  languageSelect: document.getElementById("language-select"),
  displayUnitSelect: document.getElementById("display-unit-select"),
  privacyFilterSelect: document.getElementById("privacy-filter-select"),
  privacyFilterStatus: document.getElementById("privacy-filter-status"),
  privacyFilterDetail: document.getElementById("privacy-filter-detail"),
  followXButton: document.getElementById("follow-x-button"),
  shareStoryButton: document.getElementById("share-story-button"),
  headerRefresh: document.getElementById("header-refresh-button"),
  viewButtons: Array.from(document.querySelectorAll("[data-view-button]")),
  views: Array.from(document.querySelectorAll("[data-view]")),

  homeStatus: document.getElementById("home-status"),
  homeModel: document.getElementById("home-model"),
  homeBalance: document.getElementById("home-balance"),
  homeAccount: document.getElementById("home-account"),
  homeNetworkDevices: document.getElementById("home-network-devices"),
  homeNetworkRam: document.getElementById("home-network-ram"),
  homeNetworkModels: document.getElementById("home-network-models"),
  homeNetworkTtft: document.getElementById("home-network-ttft"),
  homeNetworkTps: document.getElementById("home-network-tps"),
  homeNetworkEarnedLabel: document.getElementById("home-network-earned-label"),
  homeNetworkEarned: document.getElementById("home-network-earned"),
  homeNetworkSpentLabel: document.getElementById("home-network-spent-label"),
  homeNetworkSpent: document.getElementById("home-network-spent"),
  homeNetworkUsdc: document.getElementById("home-network-usdc"),

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

  chatThreadStrip: document.getElementById("chat-thread-strip"),
  chatModelSelect: document.getElementById("chat-model-select"),
  chatModelNote: document.getElementById("chat-model-note"),
  chatStatusNote: document.getElementById("chat-status-note"),
  chatTranscript: document.getElementById("chat-transcript"),
  chatInput: document.getElementById("chat-input"),
  chatSendButton: document.getElementById("chat-send-button"),

  walletDeviceName: document.getElementById("wallet-device-name"),
  walletDeviceId: document.getElementById("wallet-device-id"),
  walletStatus: document.getElementById("wallet-status"),
  walletModel: document.getElementById("wallet-model"),
  walletBalanceLabel: document.getElementById("wallet-balance-label"),
  walletBalance: document.getElementById("wallet-balance"),
  walletUsdc: document.getElementById("wallet-usdc"),
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
  accountGithub: document.getElementById("account-github"),
  accountPhone: document.getElementById("account-phone"),
  accountWalletBalanceLabel: document.getElementById("account-wallet-balance-label"),
  accountWalletBalance: document.getElementById("account-wallet-balance"),
  accountWalletUsdc: document.getElementById("account-wallet-usdc"),
  accountWalletNote: document.getElementById("account-wallet-note"),
  accountApiKeyNote: document.getElementById("account-api-key-note"),
  accountApiKeyLabel: document.getElementById("account-api-key-label"),
  accountApiKeyCreate: document.getElementById("account-api-key-create"),
  accountApiKeyCreatedWrap: document.getElementById("account-api-key-created-wrap"),
  accountApiKeyCreated: document.getElementById("account-api-key-created"),
  accountApiKeyCreatedCopy: document.getElementById("account-api-key-created-copy"),
  accountApiKeysList: document.getElementById("account-api-keys-list"),
  accountApiKeysEmpty: document.getElementById("account-api-keys-empty"),
  accountApiKeyStatus: document.getElementById("account-api-key-status"),
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
const DISPLAY_UNIT_STORAGE_KEY = "teale.displayUnit";
const CHAT_STORAGE_KEY = "teale.chat.v1";
const OAUTH_CALLBACK_STORAGE_KEY = "__teale_pending_oauth_callback";
const OAUTH_PROVIDER_STORAGE_KEY = "__teale_pending_oauth_provider";
const SHARE_STORY_TEXT = "I've joined the global distributed ai inference network at teale.com - earn credits to use on ai when you sleep. spend those credits to use ai for free.";
const SUPPORTED_LANGUAGES = new Set(["en", "es", "pt-BR", "fil-PH"]);
const translations = {
  en: {
    "nav.home": "teale",
    "nav.supply": "supply",
    "nav.demand": "demand",
    "nav.wallet": "wallet",
    "nav.account": "account",
    "language.label": "language",
    "view.home.description": "supply and demand distributed ai inference",
    "view.supply.description": "earn teale credits by supplying ai inference to users around the world",
    "view.demand.description": "use local models for free or buy and spend credits for more powerful models",
    "view.wallet.description": "device balances, send assets, and ledger history",
    "view.account.description": "account details, balances, send assets, and linked devices.",
    "home.prompt.overview": "overview",
    "home.prompt.network": "network",
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
    "wallet.prompt.device": "device info",
    "wallet.prompt.send": "send",
    "wallet.prompt.ledger": "ledger",
    "wallet.asset.credits": "Teale credits",
    "wallet.asset.usdc": "USDC",
    "wallet.input.recipient": "full device wallet id or account wallet id",
    "wallet.action.refresh": "Refresh",
    "wallet.action.refreshing": "Refreshing...",
    "wallet.action.sendSoon": "Send coming soon",
    "wallet.send.note": "Use full wallet IDs only. Device wallet sends target a 64-char device wallet ID or a full account wallet ID.",
    "wallet.action.export": "Export CSV",
    "account.prompt.account": "account",
    "account.prompt.wallet": "account wallet",
    "account.prompt.details": "details",
    "account.prompt.devices": "devices",
    "account.phone": "Phone",
    "account.code": "Code",
    "account.input.phone": "+1 555 123 4567",
    "account.input.code": "123456",
    "account.auth.note.default": "Signing in is not required. Teale works without an account. Sign in if you want a human account that can manage multiple devices and get support.",
    "account.send.note": "Use full wallet IDs only. Account wallet sends target a full account wallet ID or a 64-char device wallet ID.",
    "common.asset": "Asset",
    "common.recipient": "Recipient",
    "common.amount": "Amount",
    "common.memo": "Memo",
    "common.amountPlaceholder": "0",
    "common.memoPlaceholder": "optional note",
    "common.waitingLocalService": "Waiting for the local Teale service on this PC.",
    "common.noModelLoaded": "No model loaded",
    "common.syncing": "Syncing...",
    "footer.tagline": "teale.com - distributed ai inference for the world",
    "auth.status.notConfigured": "Sign-in not configured",
    "auth.status.notSignedIn": "Not signed in",
    "auth.status.signedIn": "Signed in",
    "auth.user.configure": "Signing in is optional. Teale works without an account on this PC.",
    "auth.user.prompt": "Signing in is optional. Teale works without an account.",
    "auth.note.walletStillWorks": "Account sign-in is only for people who want to manage multiple devices and get support.",
    "auth.note.claimsDevice": "Sign in with GitHub, Google, or SMS to manage multiple devices and get support.",
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
    "nav.home": "teale",
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
    "home.prompt.network": "网络",
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
    "wallet.input.recipient": "完整 device wallet id 或 account wallet id",
    "wallet.action.refresh": "刷新",
    "wallet.action.refreshing": "刷新中...",
    "wallet.action.sendSoon": "发送即将上线",
    "wallet.send.note": "仅支持完整 wallet ID。device wallet 发送仅面向 64 位字符的 device wallet ID 或完整的 account wallet ID。",
    "wallet.action.export": "导出 CSV",
    "account.prompt.account": "账户",
    "account.prompt.wallet": "账户钱包",
    "account.prompt.details": "详情",
    "account.prompt.devices": "设备",
    "account.phone": "手机号",
    "account.code": "验证码",
    "account.input.phone": "+86 138 0013 8000",
    "account.input.code": "123456",
    "account.auth.note.default": "登录不是必需的。Teale 没有账户也能使用。若你想用一个人类账户来管理多台设备并获得支持，再登录即可。",
    "account.send.note": "仅支持完整 wallet ID。account wallet 发送仅面向完整的 account wallet ID 或 64 位字符的 device wallet ID。",
    "common.asset": "资产",
    "common.recipient": "接收方",
    "common.amount": "数量",
    "common.memo": "备注",
    "common.amountPlaceholder": "0",
    "common.memoPlaceholder": "可选备注",
    "common.waitingLocalService": "正在等待这台电脑上的本地 Teale 服务。",
    "common.noModelLoaded": "未加载模型",
    "common.syncing": "同步中...",
    "footer.tagline": "teale.com - distributed ai inference for the world",
    "auth.status.notConfigured": "未配置登录",
    "auth.status.notSignedIn": "未登录",
    "auth.status.signedIn": "已登录",
    "auth.user.configure": "登录是可选的。这台电脑上的 Teale 无需账户也能使用。",
    "auth.user.prompt": "登录是可选的。Teale 没有账户也能使用。",
    "auth.note.walletStillWorks": "账户登录只面向想要管理多台设备并获得支持的人。",
    "auth.note.claimsDevice": "使用 GitHub、Google 或短信登录，以管理多台设备并获得支持。",
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
    "nav.home": "teale",
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
    "home.prompt.network": "rede",
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
    "wallet.input.recipient": "id completo da wallet do dispositivo ou id da wallet da conta",
    "wallet.action.refresh": "Atualizar",
    "wallet.action.refreshing": "Atualizando...",
    "wallet.action.sendSoon": "Envio em breve",
    "wallet.send.note": "Use apenas IDs completos. Envios da wallet do dispositivo usam um ID de wallet do dispositivo com 64 caracteres ou um ID completo de wallet da conta.",
    "wallet.action.export": "Exportar CSV",
    "account.prompt.account": "conta",
    "account.prompt.wallet": "carteira da conta",
    "account.prompt.details": "detalhes",
    "account.prompt.devices": "dispositivos",
    "account.phone": "Telefone",
    "account.code": "Código",
    "account.input.phone": "+55 11 99999-9999",
    "account.input.code": "123456",
    "account.auth.note.default": "Fazer login não é obrigatório. O Teale funciona sem conta. Entre apenas se quiser uma conta humana para gerenciar vários dispositivos e obter suporte.",
    "account.send.note": "Use apenas IDs completos. Envios da wallet da conta usam um ID completo de wallet da conta ou um ID de wallet do dispositivo com 64 caracteres.",
    "common.asset": "Ativo",
    "common.recipient": "Destinatário",
    "common.amount": "Valor",
    "common.memo": "Memo",
    "common.amountPlaceholder": "0",
    "common.memoPlaceholder": "nota opcional",
    "common.waitingLocalService": "Aguardando o serviço local do Teale neste PC.",
    "common.noModelLoaded": "Nenhum modelo carregado",
    "common.syncing": "Sincronizando...",
    "footer.tagline": "teale.com - distributed ai inference for the world",
    "auth.status.notConfigured": "Login não configurado",
    "auth.status.notSignedIn": "Sem login",
    "auth.status.signedIn": "Conectado",
    "auth.user.configure": "Fazer login é opcional. O Teale funciona sem conta neste PC.",
    "auth.user.prompt": "Fazer login é opcional. O Teale funciona sem conta.",
    "auth.note.walletStillWorks": "O login da conta é apenas para pessoas que querem gerenciar vários dispositivos e obter suporte.",
    "auth.note.claimsDevice": "Entre com GitHub, Google ou SMS para gerenciar vários dispositivos e obter suporte.",
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
    "nav.home": "teale",
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
    "home.prompt.network": "red",
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
    "wallet.input.recipient": "id completo de wallet de dispositivo o id de wallet de cuenta",
    "wallet.action.refresh": "Actualizar",
    "wallet.action.refreshing": "Actualizando...",
    "wallet.action.sendSoon": "Envío próximamente",
    "wallet.send.note": "Usa solo IDs completos. Los envíos desde la wallet del dispositivo usan un ID de wallet de dispositivo de 64 caracteres o un ID completo de wallet de cuenta.",
    "wallet.action.export": "Exportar CSV",
    "account.prompt.account": "cuenta",
    "account.prompt.wallet": "cartera de la cuenta",
    "account.prompt.details": "detalles",
    "account.prompt.devices": "dispositivos",
    "account.phone": "Teléfono",
    "account.code": "Código",
    "account.input.phone": "+34 600 123 456",
    "account.input.code": "123456",
    "account.auth.note.default": "Iniciar sesión no es obligatorio. Teale funciona sin una cuenta. Inicia sesión solo si quieres una cuenta humana para administrar varios dispositivos y obtener soporte.",
    "account.send.note": "Usa solo IDs completos. Los envíos desde la wallet de cuenta usan un ID completo de wallet de cuenta o un ID de wallet de dispositivo de 64 caracteres.",
    "common.asset": "Activo",
    "common.recipient": "Destinatario",
    "common.amount": "Cantidad",
    "common.memo": "Memo",
    "common.amountPlaceholder": "0",
    "common.memoPlaceholder": "nota opcional",
    "common.waitingLocalService": "Esperando el servicio local de Teale en esta PC.",
    "common.noModelLoaded": "Ningún modelo cargado",
    "common.syncing": "Sincronizando...",
    "footer.tagline": "teale.com - distributed ai inference for the world",
    "auth.status.notConfigured": "Inicio de sesión no configurado",
    "auth.status.notSignedIn": "Sin iniciar sesión",
    "auth.status.signedIn": "Sesión iniciada",
    "auth.user.configure": "Iniciar sesión es opcional. Teale funciona sin una cuenta en esta PC.",
    "auth.user.prompt": "Iniciar sesión es opcional. Teale funciona sin una cuenta.",
    "auth.note.walletStillWorks": "El inicio de sesión de la cuenta es solo para personas que quieren administrar varios dispositivos y obtener soporte.",
    "auth.note.claimsDevice": "Inicia sesión con GitHub, Google o SMS para administrar varios dispositivos y obtener soporte.",
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
    "nav.home": "teale",
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
    "home.prompt.network": "network",
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
    "wallet.input.recipient": "full device wallet id o account wallet id",
    "wallet.action.refresh": "Refresh",
    "wallet.action.refreshing": "Refreshing...",
    "wallet.action.sendSoon": "Papunta na ang send",
    "wallet.send.note": "Buong wallet IDs lang ang gamitin. Ang send mula sa device wallet ay para sa 64-char device wallet ID o buong account wallet ID.",
    "wallet.action.export": "I-export ang CSV",
    "account.prompt.account": "account",
    "account.prompt.wallet": "account wallet",
    "account.prompt.details": "detalye",
    "account.prompt.devices": "mga device",
    "account.phone": "Phone",
    "account.code": "Code",
    "account.input.phone": "+63 917 123 4567",
    "account.input.code": "123456",
    "account.auth.note.default": "Hindi kailangan ang pag-sign in. Gumagana ang Teale kahit walang account. Mag-sign in lang kung gusto mo ng human account para mamahala ng maraming device at makakuha ng support.",
    "account.send.note": "Buong wallet IDs lang ang gamitin. Ang send mula sa account wallet ay para sa buong account wallet ID o 64-char device wallet ID.",
    "common.asset": "Asset",
    "common.recipient": "Tatanggap",
    "common.amount": "Halaga",
    "common.memo": "Memo",
    "common.amountPlaceholder": "0",
    "common.memoPlaceholder": "opsyonal na note",
    "common.waitingLocalService": "Naghihintay sa local Teale service sa PC na ito.",
    "common.noModelLoaded": "Walang naka-load na model",
    "common.syncing": "Nagsi-sync...",
    "footer.tagline": "teale.com - distributed ai inference for the world",
    "auth.status.notConfigured": "Hindi naka-configure ang sign-in",
    "auth.status.notSignedIn": "Hindi naka-sign in",
    "auth.status.signedIn": "Naka-sign in",
    "auth.user.configure": "Opsyonal ang pag-sign in. Gumagana ang Teale kahit walang account sa PC na ito.",
    "auth.user.prompt": "Opsyonal ang pag-sign in. Gumagana ang Teale kahit walang account.",
    "auth.note.walletStillWorks": "Ang account sign-in ay para lang sa mga taong gustong mamahala ng maraming device at makakuha ng support.",
    "auth.note.claimsDevice": "Mag-sign in gamit ang GitHub, Google, o SMS para mamahala ng maraming device at makakuha ng support.",
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

const chatTranslationDefaults = {
  "chat.prompt.thread": "thread",
  "chat.prompt.message": "message",
  "chat.model.label": "Model",
  "chat.model.note": "Local is free on this PC. Network models spend Teale credits.",
  "chat.model.localNote": "Local is free on this PC.",
  "chat.model.networkNote": "Network models spend Teale credits.",
  "chat.model.waitingOption": "Waiting for available models...",
  "chat.input.placeholder": "Ask something...",
  "chat.input.hint": "Enter sends. Shift+Enter adds a newline.",
  "chat.action.send": "Send",
  "chat.action.newThread": "+ New thread",
  "chat.thread.defaultTitle": "New thread",
  "chat.thread.close": "Close thread",
  "chat.tokens.input": "{{count}} input tokens",
  "chat.tokens.inputApprox": "~{{count}} input tokens",
  "chat.tokens.output": "{{count}} output tokens",
  "chat.tokens.outputApprox": "~{{count}} output tokens",
  "chat.thread.empty": "Start a new thread. Only messages in this thread are sent as context.",
  "chat.thread.pending": "Teale is thinking...",
  "chat.thread.partialReply": "Partial reply from an interrupted stream.",
  "chat.thread.interrupted": "This partial reply stays visible for this session, but it will not be sent as context.",
  "chat.thread.streamInterrupted": "The chat stream ended before completion. The partial reply stayed on screen but was not saved to the thread.",
  "chat.thread.noModel": "No chat models are available yet.",
  "chat.thread.waitingLocal": "Load a local model or wait for live network models.",
  "chat.thread.waitingNetwork": "Waiting for the network bearer token from the gateway wallet sync.",
  "chat.thread.fallbackPrefix": "Switched to {{model}} because {{previous}} is not available on this PC.",
};

for (const locale of Object.keys(translations)) {
  Object.assign(translations[locale], chatTranslationDefaults);
}

function normalizeLanguage(candidate) {
  const value = String(candidate || "").toLowerCase();
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
    if (saved && SUPPORTED_LANGUAGES.has(saved) && translations[saved]) {
      return saved;
    }
  } catch (_error) {}
  return normalizeLanguage(window.navigator.language);
}

function normalizeDisplayUnit(value) {
  return value === "usd" ? "usd" : "credits";
}

function loadInitialDisplayUnit() {
  try {
    return normalizeDisplayUnit(window.localStorage.getItem(DISPLAY_UNIT_STORAGE_KEY));
  } catch (_error) {
    return "credits";
  }
}

let currentLanguage = loadInitialLanguage();
let displayUnit = loadInitialDisplayUnit();

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
  if (displayUnit === "usd") {
    if (view === "supply") {
      return "earn usd-equivalent balance by supplying ai inference to users around the world";
    }
    if (view === "demand") {
      return "use local models for free or buy and spend usd for more powerful models";
    }
  }
  return t(`view.${view}.description`);
}

let activeView = "home";
let intervalHandle = null;
let lastSnapshot = null;
let supabaseClient = null;
let supabaseAuthKey = null;
let authSession = null;
let authUser = null;
let pendingNativeSession = normalizeNativeSession(DESKTOP_CONFIG.nativeSession || null);
let authIdentities = [];
let accountDevices = [];
let accountSummary = null;
let accountApiKeys = [];
let createdAccountApiKeyToken = null;
let supabaseAccountDevices = [];
let linkedSupabaseUserId = null;
let linkedGatewayAccountStateKey = null;
let pendingOAuthCallbackUrl = null;
let pendingOAuthProvider = null;
let authErrorMessage = null;
let oauthReconcileInFlight = false;
let oauthCallbackExchangeInFlight = false;
let networkModels = [];
let networkModelsFetchedAt = 0;
let networkStats = null;
let networkStatsFetchedAt = 0;
let networkStatsError = null;
let selectedNetworkModelId = null;
let demandSort = { key: "devices", dir: "desc" };
let pendingModelAction = null;
let walletRefreshInFlight = false;
let walletSendInFlight = false;
let accountSendInFlight = false;
let accountApiKeyCreateInFlight = false;
let accountApiKeyRevokeInFlight = null;
let walletSendStatus = "";
let accountSendStatus = "";
let accountApiKeyStatus = "";
let accountApiKeyStatusIsError = false;
let chatState = loadChatState();
let lastNativeSyncedSessionKey = null;
let chatRuntime = {
  inFlight: null,
  interruptedDrafts: {},
  infoMessage: "",
  errorMessage: "",
};
let localApiKey = DESKTOP_CONFIG.localApiKey || null;
let localApiKeyPromise = null;
let consecutiveSnapshotFailures = 0;
let bundledFallbackAttempted = false;

function normalizeNativeSession(session) {
  if (!session?.accessToken || !session?.refreshToken) {
    return null;
  }
  return {
    accessToken: session.accessToken,
    refreshToken: session.refreshToken,
  };
}

function apiUrl(path) {
  return `${API_BASE}${path}`;
}

async function ensureLocalApiKey() {
  if (localApiKey || !ROUTES.localApiKey) {
    return localApiKey;
  }
  if (!localApiKeyPromise) {
    localApiKeyPromise = (async () => {
      const response = await fetch(ROUTES.localApiKey, { cache: "no-store" }).catch(() => null);
      if (!response?.ok) {
        return null;
      }
      const payload = await response.json().catch(() => null);
      localApiKey = payload?.key || null;
      return localApiKey;
    })().finally(() => {
      localApiKeyPromise = null;
    });
  }
  return localApiKeyPromise;
}

async function applyPendingNativeSessionIfNeeded() {
  if (!supabaseClient || !pendingNativeSession) {
    return null;
  }

  try {
    const current = await supabaseClient.auth.getSession();
    if (current?.data?.session) {
      return current.data.session;
    }
  } catch (_error) {}

  try {
    authTrace("hydrating supabase session from native shell");
    const { data, error } = await supabaseClient.auth.setSession({
      access_token: pendingNativeSession.accessToken,
      refresh_token: pendingNativeSession.refreshToken,
    });
    if (error) {
      authTrace(`native session hydrate failed ${error.message}`);
      return null;
    }
    if (data?.session) {
      authTrace(`native session hydrate success user=${data.session.user?.id || "none"}`);
      return data.session;
    }
  } catch (error) {
    authTrace(`native session hydrate threw ${friendlyError(error)}`);
  }
  return null;
}

async function apiFetch(path, init = {}) {
  const headers = new Headers(init.headers || {});
  const key = await ensureLocalApiKey();
  if (key) {
    headers.set("Authorization", `Bearer ${key}`);
  }
  return fetch(apiUrl(path), { ...init, headers });
}

function postNativeSessionSync(session) {
  const accessToken = session?.access_token;
  const refreshToken = session?.refresh_token;

  if (!accessToken || !refreshToken) {
    // Only emit authSignOut after we've previously synced a real session.
    // On initial bootstrap the native shell may still be hydrating its tokens
    // into the page; emitting signOut here would clobber the native session
    // and leave the user signed-out everywhere even though they're signed in
    // on the native side.
    if (
      lastNativeSyncedSessionKey &&
      lastNativeSyncedSessionKey !== "__signed_out__"
    ) {
      postNativeMessage({ type: "authSignOut" });
      lastNativeSyncedSessionKey = "__signed_out__";
    }
    return;
  }

  const sessionKey = `${accessToken}:${refreshToken}`;
  if (lastNativeSyncedSessionKey === sessionKey) {
    return;
  }

  postNativeMessage({
    type: "authSession",
    accessToken,
    refreshToken,
  });
  lastNativeSyncedSessionKey = sessionKey;
}

function updateDisplayUnitLabels() {
  if (els.displayUnitSelect) {
    els.displayUnitSelect.value = displayUnit;
  }
  if (els.homeNetworkEarnedLabel) {
    els.homeNetworkEarnedLabel.textContent = displayUnit === "usd" ? "Total USD earned" : "Total credits earned";
  }
  if (els.homeNetworkSpentLabel) {
    els.homeNetworkSpentLabel.textContent = displayUnit === "usd" ? "Total USD spent" : "Total credits spent";
  }
  if (els.walletBalanceLabel) {
    els.walletBalanceLabel.textContent = displayUnit === "usd" ? "USD" : "Teale credits";
  }
  if (els.accountWalletBalanceLabel) {
    els.accountWalletBalanceLabel.textContent = displayUnit === "usd" ? "USD" : "Teale credits";
  }
  if (els.sendAmount) {
    els.sendAmount.placeholder = displayUnit === "usd" ? "0.00" : "0";
  }
  if (els.accountSendAmount) {
    els.accountSendAmount.placeholder = displayUnit === "usd" ? "0.00" : "0";
  }
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
  updateDisplayUnitLabels();
}

function setLanguage(language) {
  currentLanguage = SUPPORTED_LANGUAGES.has(language) && translations[language] ? language : "en";
  try {
    window.localStorage.setItem(LANGUAGE_STORAGE_KEY, currentLanguage);
  } catch (_error) {}
  applyTranslations();
  if (els.settingsMenu) {
    els.settingsMenu.open = false;
  }
  setActiveView(activeView);
  if (lastSnapshot) {
    render(lastSnapshot);
  } else {
    renderChat(lastSnapshot);
    renderAuthState();
    renderAccountWallet();
    renderAccountApiKeys();
    renderAccountDevices();
  }
}

function setDisplayUnit(nextValue) {
  displayUnit = normalizeDisplayUnit(nextValue);
  try {
    window.localStorage.setItem(DISPLAY_UNIT_STORAGE_KEY, displayUnit);
  } catch (_error) {}
  updateDisplayUnitLabels();
  els.headerLine.textContent = viewDescription(activeView) || viewDescription("home");
  if (els.settingsMenu) {
    els.settingsMenu.open = false;
  }
  if (lastSnapshot) {
    render(lastSnapshot);
  } else {
    renderHomeNetworkStats();
    renderAuthState();
    renderAccountWallet();
    renderAccountApiKeys();
    renderAccountDevices();
    updateSendControls();
    renderChat(lastSnapshot);
  }
}

function privacyHelperLabel(state) {
  switch (state) {
    case "ready":
      return "Helper status: ready";
    case "unavailable":
      return "Helper status: unavailable";
    case "unsupported":
      return "Helper status: unsupported";
    default:
      return "Helper status: disabled";
  }
}

function renderPrivacyFilter(snapshot = lastSnapshot) {
  const privacy = snapshot?.privacy_filter || {};
  const mode = privacy.mode || "off";
  const helperStatus = privacy.helper_status || "disabled";
  const helperDetail = privacy.helper_detail || "Privacy filtering is off.";

  if (els.privacyFilterSelect) {
    els.privacyFilterSelect.value = mode;
  }
  if (els.privacyFilterStatus) {
    els.privacyFilterStatus.textContent = privacyHelperLabel(helperStatus);
  }
  if (els.privacyFilterDetail) {
    els.privacyFilterDetail.textContent = helperDetail;
  }
}

async function setPrivacyFilterMode(mode) {
  const response = await post(ROUTES.privacyFilterMode, { mode });
  render(response);
  return response;
}

function providerDisplayName(provider) {
  return t(`provider.${provider}`);
}

function authConfigHint(provider, message) {
  const lower = String(message || "").toLowerCase();
  if (
    provider === "github" &&
    (lower.includes("client_id") ||
      lower.includes("client id") ||
      lower.includes("oauth app") ||
      lower.includes("teale app"))
  ) {
    return "GitHub sign-in is misconfigured in Supabase. Set the GitHub provider client ID to the real GitHub OAuth Client ID, not the app name, and keep the callback URL at https://<project-ref>.supabase.co/auth/v1/callback.";
  }
  if (
    provider === "google" &&
    (
      lower.includes("invalid_client") ||
      lower.includes("client_id") ||
      lower.includes("client id") ||
      lower.includes("oauth client") ||
      lower === "teale.com" ||
      (lower.includes(".") && !lower.includes(".apps.googleusercontent.com"))
    )
  ) {
    return "Google sign-in is misconfigured in Supabase. Use a Google Web application OAuth client, put the Supabase callback URL under Authorized redirect URIs, and save the same client ID and secret in the Supabase Google provider.";
  }
  return message;
}

function authConfigHintFromMessage(message) {
  const lower = String(message || "").toLowerCase();
  if (lower.includes("github")) {
    return authConfigHint("github", message);
  }
  if (lower.includes("google") || lower.includes("invalid_client")) {
    return authConfigHint("google", message);
  }
  if (
    lower.includes("pkce") ||
    lower.includes("code verifier") ||
    lower.includes("code_verifier")
  ) {
    return "Sign-in expired before Teale could finish it. Try signing in again from the Teale app.";
  }
  return message;
}

function setAuthErrorState(message) {
  authErrorMessage = message;
  els.authStatus.textContent = "Sign-in failed";
  els.authUser.textContent = message;
}

function clearAuthErrorState() {
  authErrorMessage = null;
}

function currentSupabaseProjectRef() {
  const supabaseUrl = lastSnapshot?.auth?.supabase_url;
  if (!supabaseUrl) {
    return null;
  }
  try {
    return new URL(supabaseUrl).host.split(".")[0] || null;
  } catch (_error) {
    return null;
  }
}

function clearPersistedSupabaseSession() {
  const projectRef = currentSupabaseProjectRef();
  if (!projectRef) {
    return;
  }
  const keys = [
    `sb-${projectRef}-auth-token`,
    `sb-${projectRef}-auth-token-code-verifier`,
    `sb-${projectRef}-auth-token-code-verifiers`,
  ];
  for (const key of keys) {
    try {
      window.localStorage.removeItem(key);
    } catch (_error) {}
  }
}

function loadPersistedSupabaseSession() {
  const projectRef = currentSupabaseProjectRef();
  if (!projectRef) {
    return null;
  }
  try {
    const raw = window.localStorage.getItem(`sb-${projectRef}-auth-token`);
    if (!raw) {
      return null;
    }
    const parsed = JSON.parse(raw);
    if (!parsed?.access_token || !parsed?.refresh_token) {
      return null;
    }
    return parsed;
  } catch (_error) {
    return null;
  }
}

async function restorePersistedSupabaseSession() {
  if (!supabaseClient) {
    return null;
  }
  const storedSession = loadPersistedSupabaseSession();
  if (!storedSession?.access_token || !storedSession?.refresh_token) {
    return null;
  }

  try {
    authTrace("restoring persisted supabase session from local storage");
    const { data, error } = await withTimeout(
      supabaseClient.auth.setSession({
        access_token: storedSession.access_token,
        refresh_token: storedSession.refresh_token,
      }),
      15000,
      "restore stored session"
    );
    if (error) {
      throw error;
    }
    authTrace(`restore stored session success user=${data.session?.user?.id || "none"}`);
    return data.session || null;
  } catch (error) {
    authTrace(`restore stored session failed ${error.message}`);
    return null;
  }
}

function resetAccountAuthState() {
  authSession = null;
  authUser = null;
  authIdentities = [];
  linkedSupabaseUserId = null;
  linkedGatewayAccountStateKey = null;
  accountDevices = [];
  accountSummary = null;
  accountApiKeys = [];
  createdAccountApiKeyToken = null;
  accountApiKeyStatus = "";
  accountApiKeyStatusIsError = false;
  supabaseAccountDevices = [];
  clearAuthErrorState();
  clearPendingOAuthProvider();
  clearStoredOAuthCallback();
  els.authPhoneInput.value = "";
  els.authPhoneCodeInput.value = "";
  renderAccountWallet();
  renderAccountApiKeys();
  renderAuthState();
  renderAccountDevices();
  renderHome(lastSnapshot);
}

function callbackParams(url) {
  const parsed = new URL(url);
  const hash = parsed.hash.startsWith("#") ? parsed.hash.slice(1) : parsed.hash;
  return {
    parsed,
    search: parsed.searchParams,
    hash: new URLSearchParams(hash),
  };
}

function callbackValue(params, key) {
  return params.search.get(key) || params.hash.get(key);
}

function summarizeCallbackUrl(url) {
  try {
    const params = callbackParams(url);
    const keys = Array.from(new Set([
      ...Array.from(params.search.keys()),
      ...Array.from(params.hash.keys()),
    ])).sort();
    const parsed = new URL(url);
    return `${parsed.protocol}//${parsed.host}${parsed.pathname} keys=[${keys.join(",")}]`;
  } catch (_error) {
    return "unparseable";
  }
}

function loadStoredOAuthCallback() {
  if (pendingOAuthCallbackUrl) {
    return pendingOAuthCallbackUrl;
  }
  try {
    const stored = window.localStorage.getItem(OAUTH_CALLBACK_STORAGE_KEY);
    if (stored) {
      pendingOAuthCallbackUrl = stored;
      return stored;
    }
  } catch (_error) {}
  return pendingOAuthCallbackUrl;
}

function clearStoredOAuthCallback() {
  pendingOAuthCallbackUrl = null;
  try {
    window.localStorage.removeItem(OAUTH_CALLBACK_STORAGE_KEY);
  } catch (_error) {}
}

function setPendingOAuthProvider(provider) {
  pendingOAuthProvider = provider || null;
  try {
    if (pendingOAuthProvider) {
      window.localStorage.setItem(OAUTH_PROVIDER_STORAGE_KEY, pendingOAuthProvider);
    } else {
      window.localStorage.removeItem(OAUTH_PROVIDER_STORAGE_KEY);
    }
  } catch (_error) {}
}

function loadPendingOAuthProvider() {
  if (pendingOAuthProvider) {
    return pendingOAuthProvider;
  }
  try {
    const stored = window.localStorage.getItem(OAUTH_PROVIDER_STORAGE_KEY);
    if (stored) {
      pendingOAuthProvider = stored;
      return stored;
    }
  } catch (_error) {}
  return pendingOAuthProvider;
}

function clearPendingOAuthProvider() {
  setPendingOAuthProvider(null);
}

async function syncNativePendingOAuthCallback() {
  if (!ROUTES.authPending) {
    return;
  }
  try {
    const response = await fetch(ROUTES.authPending, { cache: "no-store" });
    if (!response.ok) {
      return;
    }
    const payload = await response.json();
    if (!payload?.url) {
      return;
    }
    authTrace(`native pending callback ${summarizeCallbackUrl(payload.url)}`);
    pendingOAuthCallbackUrl = payload.url;
    try {
      window.localStorage.setItem(OAUTH_CALLBACK_STORAGE_KEY, payload.url);
    } catch (_error) {}
  } catch (_error) {}
}

function oauthMisconfigFromUrl(provider, rawUrl) {
  try {
    const parsed = new URL(rawUrl);
    const clientId = parsed.searchParams.get("client_id");
    if (!clientId) {
      return null;
    }
    if (provider === "github" && /\s/.test(clientId)) {
      return authConfigHint(provider, clientId);
    }
    if (provider === "google" && !clientId.includes(".apps.googleusercontent.com")) {
      return authConfigHint(provider, clientId);
    }
  } catch (_error) {}
  return null;
}

function userDisplayName(user) {
  const metadata = user?.user_metadata || {};
  return metadata.full_name || metadata.name || metadata.user_name || user?.email || user?.phone || null;
}

function identityDataValue(identity, ...keys) {
  const identityData = identity?.identity_data || {};
  for (const key of keys) {
    const value = identityData[key];
    if (typeof value === "string" && value.trim()) {
      return value.trim();
    }
  }
  return null;
}

function githubUsernameForIdentities(identities) {
  const githubIdentity = (identities || []).find((identity) => identity.provider === "github");
  return identityDataValue(githubIdentity, "user_name", "preferred_username", "login", "name");
}

function accountLinkStateKey(user, identities) {
  if (!user?.id) {
    return null;
  }
  const identityKey = (identities || [])
    .map((identity) => {
      const providerKey =
        identityDataValue(identity, "user_name", "preferred_username", "login", "email", "phone", "sub") ||
        identity.id ||
        identity.identity_id ||
        "";
      return `${identity.provider || "unknown"}:${providerKey}`;
    })
    .sort()
    .join("|");
  return [user.id, user.phone || "", user.email || "", identityKey].join("||");
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

function creditsToUsd(credits) {
  const numeric = Number(credits);
  if (!Number.isFinite(numeric)) {
    return null;
  }
  return numeric / 1_000_000;
}

function formatUsdValue(value) {
  const numeric = Number(value);
  if (!Number.isFinite(numeric)) {
    return "-";
  }
  if (numeric >= 1) {
    return `$${numeric.toFixed(2)}`;
  }
  return `$${numeric.toFixed(4)}`;
}

function formatDisplayCredits(value, includeUnit = false) {
  if (displayUnit === "usd") {
    const usd = creditsToUsd(value);
    const formatted = formatUsdValue(usd);
    return includeUnit ? `${formatted} USD` : formatted;
  }
  const formatted = formatCredits(value);
  return includeUnit ? `${formatted} credits` : formatted;
}

function formatDisplayCreditsCompact(value) {
  if (displayUnit === "usd") {
    const usd = creditsToUsd(value);
    return formatPricePerMillionUsd((usd ?? 0) / 1_000_000);
  }
  return formatCompactCredits(value);
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
    case "offline":
      return "Offline";
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

function formatPricePerMillionUsd(value) {
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

function formatPricePerMillionDisplay(value) {
  const numeric = Number(value);
  if (!Number.isFinite(numeric)) {
    return "-";
  }
  if (displayUnit === "usd") {
    return formatPricePerMillionUsd(value);
  }
  return formatCredits(Math.round(creditsPerMillionFromUsdToken(value) || 0));
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

async function copyValueWithFlash(button, value, label, renderValue) {
  if (!value || value === "-") {
    return;
  }
  const original = renderValue(value);
  try {
    await copyTextQuiet(value);
    button.textContent = t("common.copied", { fallback: "copied" });
    window.setTimeout(() => {
      button.textContent = original;
    }, 900);
  } catch (error) {
    alert(`Could not copy ${label.toLowerCase()}: ${error.message}`);
  }
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

function linkedProviderNames() {
  const providers = new Set();
  for (const identity of authIdentities || []) {
    if (identity?.provider) {
      providers.add(identity.provider);
    }
  }
  for (const identity of authUser?.identities || []) {
    if (identity?.provider) {
      providers.add(identity.provider);
    }
  }
  const metadataProviders = authUser?.app_metadata?.providers;
  if (Array.isArray(metadataProviders)) {
    for (const provider of metadataProviders) {
      if (typeof provider === "string" && provider) {
        providers.add(provider);
      }
    }
  }
  if (authUser?.phone || accountSummary?.phone) {
    providers.add("phone");
  }
  if (accountSummary?.github_username) {
    providers.add("github");
  }
  return Array.from(providers);
}

function linkedEmails() {
  const emails = new Set();
  const pushEmail = (value) => {
    if (typeof value === "string" && value.trim()) {
      emails.add(value.trim().toLowerCase());
    }
  };

  pushEmail(authUser?.email);
  pushEmail(accountSummary?.email);

  for (const identity of authIdentities || []) {
    pushEmail(identity?.email);
    pushEmail(identityDataValue(identity, "email"));
  }

  for (const identity of authUser?.identities || []) {
    pushEmail(identity?.email);
    pushEmail(identityDataValue(identity, "email"));
  }

  return Array.from(emails);
}

function primaryLinkedEmail() {
  return linkedEmails()[0] || null;
}

function linkedGithubUsername() {
  return githubUsernameForIdentities(authIdentities)
    || githubUsernameForIdentities(authUser?.identities || [])
    || accountSummary?.github_username
    || null;
}

function availabilityRateLabel(wallet) {
  const tickCredits = wallet?.availability_credits_per_tick ?? 0;
  const tickSeconds = wallet?.availability_tick_seconds ?? 10;
  if (tickCredits > 0) {
    const amount = displayUnit === "usd"
      ? formatUsdValue(creditsToUsd(tickCredits))
      : formatCredits(tickCredits);
    if (tickSeconds === 1) {
      return `+${amount} / sec`;
    }
    return `+${amount} / ${tickSeconds} sec`;
  }
  const perMinute = wallet?.availability_rate_credits_per_minute ?? 0;
  if (perMinute > 0) {
    const amount = displayUnit === "usd"
      ? formatUsdValue(creditsToUsd(perMinute))
      : formatCredits(perMinute);
    return `+${amount} / min`;
  }
  return t("wallet.rate.waiting", {
    fallback: "Availability earnings begin once a compatible model is loaded and serving.",
  });
}

function walletStatusNote(wallet) {
  if (wallet?.gateway_sync_error) {
    return t("wallet.note.retrying", {
      fallback: "Balance is showing locally. Gateway sync is retrying in the background.",
    });
  }
  return t("wallet.note.live", {
    fallback: "Balance increases while supply is live. Network inference spends from this same balance.",
  });
}

function visibleWalletTransactions(entries) {
  return (entries || []).filter((entry) => (entry?.type || entry?.type_ || "").toUpperCase() !== "AVAILABILITY_DRIP");
}

function deviceWalletBalance() {
  return {
    credits: lastSnapshot?.wallet?.gateway_balance_credits ?? null,
    usdcCents: lastSnapshot?.wallet?.gateway_usdc_cents ?? 0,
    note: walletStatusNote(lastSnapshot?.wallet),
    transactions: visibleWalletTransactions(lastSnapshot?.wallet_transactions),
  };
}

function accountWalletBalance() {
  return {
    credits: accountSummary?.balance_credits ?? null,
    usdcCents: accountSummary?.usdc_cents ?? 0,
    note: t("account.wallet.note.live", {
      fallback: "Account balance includes swept device balances and receives transfers sent to your linked account identifiers.",
    }),
    transactions: visibleWalletTransactions(accountSummary?.transactions),
  };
}

function parseDisplayAmountToCredits(rawValue) {
  const trimmed = rawValue.trim();
  if (!trimmed) {
    return null;
  }

  if (displayUnit === "usd") {
    const normalized = trimmed.replaceAll(",", "");
    if (!/^\d+(\.\d+)?$/.test(normalized)) {
      return Number.NaN;
    }
    const usd = Number.parseFloat(normalized);
    const credits = Math.round(usd * 1_000_000);
    if (!Number.isSafeInteger(credits) || credits <= 0) {
      return Number.NaN;
    }
    return credits;
  }

  if (!/^\d+$/.test(trimmed)) {
    return Number.NaN;
  }
  const credits = Number.parseInt(trimmed, 10);
  if (!Number.isSafeInteger(credits) || credits <= 0) {
    return Number.NaN;
  }
  return credits;
}

function invalidAmountMessage() {
  return displayUnit === "usd"
    ? "Enter a USD amount greater than 0."
    : "Enter a whole-number credit amount.";
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
  const visible = visibleNetworkModels();
  return visible.find((model) => model.id === selectedNetworkModelId) || visible[0] || null;
}

function visibleNetworkModels() {
  return networkModels.filter((model) => {
    const id = String(model?.id || "");
    return Boolean(id) && !id.startsWith("teale/");
  });
}

function createId() {
  if (window.crypto?.randomUUID) {
    return window.crypto.randomUUID();
  }
  return `chat-${Date.now()}-${Math.random().toString(16).slice(2)}`;
}

function cloneModelTarget(target) {
  if (!target?.provider || !target?.modelId) {
    return null;
  }
  return {
    provider: target.provider,
    modelId: target.modelId,
  };
}

function normalizeChatTimestamp(value) {
  const numeric = Number(value);
  return Number.isFinite(numeric) && numeric > 0 ? numeric : Date.now();
}

function createChatThread(initialTarget = null) {
  const now = Date.now();
  return {
    id: createId(),
    title: t("chat.thread.defaultTitle"),
    modelTarget: cloneModelTarget(initialTarget),
    createdAt: now,
    updatedAt: now,
    messages: [],
  };
}

function createInitialChatState() {
  const thread = createChatThread();
  return {
    selectedThreadId: thread.id,
    threads: [thread],
  };
}

function sanitizeChatMessage(raw) {
  if (!raw || (raw.role !== "user" && raw.role !== "assistant")) {
    return null;
  }
  const content = typeof raw.content === "string" ? raw.content : "";
  if (!content) {
    return null;
  }
  return {
    id: typeof raw.id === "string" && raw.id ? raw.id : createId(),
    role: raw.role,
    content,
    createdAt: normalizeChatTimestamp(raw.createdAt),
    tokenCount: normalizeTokenCount(raw.tokenCount),
    tokenEstimated: Boolean(raw.tokenEstimated),
    quotedCostCredits: normalizeCreditCount(raw.quotedCostCredits),
    billedCostCredits: normalizeCreditCount(raw.billedCostCredits),
    costEstimated: Boolean(raw.costEstimated),
    costFree: Boolean(raw.costFree),
  };
}

function sanitizeChatThread(raw) {
  if (!raw || typeof raw !== "object") {
    return null;
  }
  const id = typeof raw.id === "string" && raw.id ? raw.id : createId();
  const messages = Array.isArray(raw.messages) ? raw.messages.map(sanitizeChatMessage).filter(Boolean) : [];
  const modelTarget = cloneModelTarget(raw.modelTarget);
  const createdAt = normalizeChatTimestamp(raw.createdAt);
  const updatedAt = normalizeChatTimestamp(raw.updatedAt);
  return {
    id,
    title: typeof raw.title === "string" && raw.title ? raw.title : t("chat.thread.defaultTitle"),
    modelTarget,
    createdAt,
    updatedAt: Math.max(updatedAt, createdAt),
    messages,
  };
}

function sortedChatThreads() {
  return chatState.threads
    .slice()
    .sort((left, right) => (right.updatedAt - left.updatedAt) || (right.createdAt - left.createdAt));
}

function ensureSelectedThread() {
  if (!chatState.threads.length) {
    chatState = createInitialChatState();
    persistChatState();
    return chatState.threads[0];
  }
  const selected = chatState.threads.find((thread) => thread.id === chatState.selectedThreadId);
  if (selected) {
    return selected;
  }
  const fallback = sortedChatThreads()[0];
  chatState.selectedThreadId = fallback.id;
  persistChatState();
  return fallback;
}

function loadChatState() {
  try {
    const raw = window.localStorage.getItem(CHAT_STORAGE_KEY);
    if (!raw) {
      return createInitialChatState();
    }
    const parsed = JSON.parse(raw);
    const threads = Array.isArray(parsed?.threads) ? parsed.threads.map(sanitizeChatThread).filter(Boolean) : [];
    if (!threads.length) {
      return createInitialChatState();
    }
    const selectedThreadId = typeof parsed.selectedThreadId === "string" ? parsed.selectedThreadId : threads[0].id;
    return { selectedThreadId, threads };
  } catch (_error) {
    return createInitialChatState();
  }
}

function persistChatState() {
  try {
    window.localStorage.setItem(
      CHAT_STORAGE_KEY,
      JSON.stringify({
        selectedThreadId: chatState.selectedThreadId,
        threads: chatState.threads,
      })
    );
  } catch (_error) {}
}

function selectedChatThread() {
  return ensureSelectedThread();
}

function normalizeThreadTitle(text) {
  const compact = String(text || "").trim().replace(/\s+/g, " ");
  if (!compact) {
    return t("chat.thread.defaultTitle");
  }
  if (compact.length <= 32) {
    return compact;
  }
  return `${compact.slice(0, 32).trimEnd()}...`;
}

function normalizeTokenCount(value) {
  const numeric = Number(value);
  if (!Number.isFinite(numeric) || numeric < 0) {
    return null;
  }
  return Math.round(numeric);
}

function normalizeCreditCount(value) {
  const numeric = Number(value);
  if (!Number.isFinite(numeric) || numeric < 0) {
    return null;
  }
  return Math.round(numeric);
}

function estimateChatTextTokens(text) {
  const bytes = new TextEncoder().encode(String(text || "")).length;
  if (!bytes) {
    return 0;
  }
  return Math.max(1, Math.ceil(bytes / 4));
}

function estimateChatPromptTokens(messages) {
  const promptBytes = (messages || []).reduce((sum, message) => {
    return sum + new TextEncoder().encode(String(message?.content || "")).length;
  }, 0);
  return Math.ceil(promptBytes / 4) + 16;
}

function formatChatUsageMeta(role, tokenCount, estimated = false) {
  const normalized = normalizeTokenCount(tokenCount);
  if (normalized == null) {
    return "";
  }
  const count = formatCredits(normalized);
  if (role === "user") {
    return t(estimated ? "chat.tokens.inputApprox" : "chat.tokens.input", { count });
  }
  return t(estimated ? "chat.tokens.outputApprox" : "chat.tokens.output", { count });
}

function chatMessageUsageMeta(message) {
  if (!message) {
    return "";
  }
  return formatChatUsageMeta(message.role, message.tokenCount, Boolean(message.tokenEstimated));
}

function parseChatUsage(raw) {
  const promptTokens = normalizeTokenCount(raw?.prompt_tokens);
  const completionTokens = normalizeTokenCount(raw?.completion_tokens);
  if (promptTokens == null && completionTokens == null) {
    return null;
  }
  return {
    promptTokens,
    completionTokens,
  };
}

function findChatPricingModel(target) {
  if (!target?.modelId) {
    return null;
  }
  return networkModels.find((model) => model.id === target.modelId) || null;
}

function quoteChatCostCredits(target, role, tokenCount) {
  const normalizedTokens = normalizeTokenCount(tokenCount);
  if (normalizedTokens == null || !target?.modelId) {
    return null;
  }
  const pricing = findChatPricingModel(target);
  if (!pricing) {
    return null;
  }
  const usdPerToken = role === "user" ? Number(pricing.prompt) : Number(pricing.completion);
  if (!Number.isFinite(usdPerToken)) {
    return null;
  }
  return normalizeCreditCount(normalizedTokens * usdPerToken * 1_000_000);
}

function formatChatCostLabel(costCredits, estimated = false) {
  const normalized = normalizeCreditCount(costCredits);
  if (normalized == null) {
    return "";
  }
  const label = formatDisplayCredits(normalized, true);
  return estimated ? `~${label}` : label;
}

function buildChatMetaNode({ role, tokenCount, tokenEstimated = false, quotedCostCredits = null, billedCostCredits = null, costEstimated = false, costFree = false }) {
  const tokenText = formatChatUsageMeta(role, tokenCount, tokenEstimated);
  const quotedCostText = formatChatCostLabel(quotedCostCredits, costEstimated);
  const billedCostText = costFree ? "" : formatChatCostLabel(billedCostCredits, costEstimated);
  if (!tokenText && !quotedCostText && !billedCostText && !costFree) {
    return null;
  }

  const meta = document.createElement("div");
  meta.className = "chat-bubble-meta";

  if (tokenText) {
    const tokenSpan = document.createElement("span");
    tokenSpan.textContent = tokenText;
    meta.appendChild(tokenSpan);
  }

  if (quotedCostText || billedCostText || costFree) {
    if (tokenText) {
      const separator = document.createElement("span");
      separator.textContent = " · ";
      meta.appendChild(separator);
    }

    if (costFree) {
      if (quotedCostText) {
        const strike = document.createElement("span");
        strike.className = "chat-bubble-meta-cost-strike";
        strike.textContent = quotedCostText;
        meta.appendChild(strike);

        const spacer = document.createElement("span");
        spacer.textContent = " ";
        meta.appendChild(spacer);
      }

      const free = document.createElement("span");
      free.className = "chat-bubble-meta-cost-free";
      free.textContent = "FREE";
      meta.appendChild(free);
    } else if (billedCostText) {
      const cost = document.createElement("span");
      cost.textContent = billedCostText;
      meta.appendChild(cost);
    }
  }

  return meta;
}

function buildChatMessageMetaNode(message) {
  if (!message) {
    return null;
  }
  return buildChatMetaNode({
    role: message.role,
    tokenCount: message.tokenCount,
    tokenEstimated: message.tokenEstimated,
    quotedCostCredits: message.quotedCostCredits,
    billedCostCredits: message.billedCostCredits,
    costEstimated: message.costEstimated,
    costFree: message.costFree,
  });
}

function creditsPerMillionFromUsdToken(value) {
  const numeric = Number(value);
  if (!Number.isFinite(numeric)) {
    return null;
  }
  return numeric * 1_000_000 * 1_000_000;
}

function formatCompactCredits(value) {
  const numeric = Number(value);
  if (!Number.isFinite(numeric)) {
    return "-";
  }
  const abs = Math.abs(numeric);
  if (abs >= 1_000_000) {
    return `${Math.max(1, Math.round(numeric / 1_000_000))}M`;
  }
  if (abs >= 1_000) {
    return `${Math.max(1, Math.round(numeric / 1_000))}K`;
  }
  return `${Math.max(0, Math.round(numeric))}`;
}

function chatTargetKey(target) {
  return target?.provider && target?.modelId ? `${target.provider}:${target.modelId}` : "";
}

function describeChatTarget(target) {
  if (!target?.modelId) {
    return "-";
  }
  return target.provider === "local"
    ? `FREE - ${shortModelLabel(target.modelId)}`
    : shortModelLabel(target.modelId);
}

function currentChatModelOptions(snapshot = lastSnapshot) {
  const options = [];

  if (snapshot?.loaded_model_id) {
    options.push({
      provider: "local",
      modelId: snapshot.loaded_model_id,
      label: `FREE - ${shortModelLabel(snapshot.loaded_model_id)}`,
      note: t("chat.model.localNote"),
    });
  }

  const paid = visibleNetworkModels()
    .slice()
    .sort((left, right) => {
      const deviceDelta = Number(right.devices || 0) - Number(left.devices || 0);
      if (deviceDelta) {
        return deviceDelta;
      }
      const leftCompletion = creditsPerMillionFromUsdToken(left.completion) ?? Number.POSITIVE_INFINITY;
      const rightCompletion = creditsPerMillionFromUsdToken(right.completion) ?? Number.POSITIVE_INFINITY;
      if (leftCompletion !== rightCompletion) {
        return leftCompletion - rightCompletion;
      }
      return String(left.id).localeCompare(String(right.id));
    });

  for (const model of paid) {
    const inputCredits = displayUnit === "usd"
      ? formatPricePerMillionUsd(model.prompt)
      : formatCompactCredits(creditsPerMillionFromUsdToken(model.prompt));
    const outputCredits = displayUnit === "usd"
      ? formatPricePerMillionUsd(model.completion)
      : formatCompactCredits(creditsPerMillionFromUsdToken(model.completion));
    options.push({
      provider: "network",
      modelId: model.id,
      label: `${inputCredits}i/${outputCredits}o/1M - ${shortModelLabel(model.id)}`,
      note: `Network models spend ${displayUnit === "usd" ? "USD" : "Teale credits"}.`,
    });
  }

  return options;
}

function reconcileChatState(snapshot = lastSnapshot, announceFallback = true) {
  if (!chatState?.threads?.length) {
    chatState = createInitialChatState();
  }

  const options = currentChatModelOptions(snapshot);
  const optionMap = new Map(options.map((option) => [chatTargetKey(option), option]));
  let changed = false;
  let announced = false;

  for (const thread of chatState.threads) {
    const previousTarget = cloneModelTarget(thread.modelTarget);
    const previousKey = chatTargetKey(previousTarget);
    if (previousKey && optionMap.has(previousKey)) {
      continue;
    }

    const fallback = options[0] ? { provider: options[0].provider, modelId: options[0].modelId } : null;
    if (!fallback) {
      continue;
    }
    const fallbackKey = chatTargetKey(fallback);
    if (previousKey !== fallbackKey) {
      thread.modelTarget = cloneModelTarget(fallback);
      changed = true;
      if (
        announceFallback &&
        !announced &&
        thread.id === chatState.selectedThreadId &&
        previousTarget?.modelId &&
        fallback?.modelId
      ) {
        chatRuntime.infoMessage = t("chat.thread.fallbackPrefix", {
          model: describeChatTarget(fallback),
          previous: describeChatTarget(previousTarget),
        });
        announced = true;
      }
    }
  }

  const selected = ensureSelectedThread();
  if (!selected.modelTarget && options[0]) {
    selected.modelTarget = { provider: options[0].provider, modelId: options[0].modelId };
    changed = true;
  }

  if (changed) {
    persistChatState();
  }

  return {
    thread: selected,
    options,
  };
}

function isChatBusy() {
  return Boolean(chatRuntime.inFlight);
}

function currentInterruptedDraft(threadId) {
  return chatRuntime.interruptedDrafts[threadId] || "";
}

function closeChatThread(threadId) {
  if (isChatBusy()) {
    return;
  }

  const index = chatState.threads.findIndex((thread) => thread.id === threadId);
  if (index === -1) {
    return;
  }

  const [closedThread] = chatState.threads.splice(index, 1);
  const wasSelected = chatState.selectedThreadId === threadId;
  delete chatRuntime.interruptedDrafts[threadId];

  if (!chatState.threads.length) {
    const replacement = createChatThread(cloneModelTarget(closedThread?.modelTarget));
    chatState.threads = [replacement];
    chatState.selectedThreadId = replacement.id;
  } else if (wasSelected) {
    const fallback = sortedChatThreads()[0];
    chatState.selectedThreadId = fallback.id;
  }

  chatRuntime.errorMessage = "";
  chatRuntime.infoMessage = "";
  persistChatState();
  renderChat(lastSnapshot);
  els.chatInput?.focus();
}

function renderChatStatus() {
  const message = chatRuntime.errorMessage || chatRuntime.infoMessage;
  if (!message) {
    els.chatStatusNote.hidden = true;
    els.chatStatusNote.textContent = "";
    els.chatStatusNote.className = "chat-status";
    return;
  }
  els.chatStatusNote.hidden = false;
  els.chatStatusNote.textContent = message;
  els.chatStatusNote.className = chatRuntime.errorMessage ? "chat-status is-error" : "chat-status is-note";
}

function renderChatThreadStrip(activeThread) {
  els.chatThreadStrip.innerHTML = "";

  for (const thread of sortedChatThreads()) {
    const chip = document.createElement("div");
    chip.className = "chat-thread-chip";
    if (thread.id === activeThread.id) {
      chip.classList.add("is-active");
    }
    if (isChatBusy()) {
      chip.classList.add("is-disabled");
    }

    const selectThread = () => {
      if (isChatBusy()) {
        return;
      }
      chatState.selectedThreadId = thread.id;
      chatRuntime.errorMessage = "";
      chatRuntime.infoMessage = "";
      persistChatState();
      renderChat(lastSnapshot);
    };

    chip.addEventListener("click", selectThread);

    const labelButton = document.createElement("button");
    labelButton.type = "button";
    labelButton.className = "chat-thread-chip-label";
    labelButton.textContent = thread.title;
    labelButton.disabled = isChatBusy();

    const closeButton = document.createElement("button");
    closeButton.type = "button";
    closeButton.className = "chat-thread-chip-close";
    closeButton.disabled = isChatBusy();
    closeButton.setAttribute("aria-label", t("chat.thread.close"));
    closeButton.title = t("chat.thread.close");
    closeButton.addEventListener("click", (event) => {
      event.stopPropagation();
      closeChatThread(thread.id);
    });

    chip.append(labelButton, closeButton);
    els.chatThreadStrip.appendChild(chip);
  }

  const createButton = document.createElement("button");
  createButton.type = "button";
  createButton.className = "chat-thread-create";
  createButton.textContent = t("chat.action.newThread");
  createButton.disabled = isChatBusy();
  createButton.addEventListener("click", () => {
    if (isChatBusy()) {
      return;
    }
    const options = currentChatModelOptions(lastSnapshot);
    const thread = createChatThread(options[0] ? { provider: options[0].provider, modelId: options[0].modelId } : null);
    chatState.threads.push(thread);
    chatState.selectedThreadId = thread.id;
    chatRuntime.errorMessage = "";
    chatRuntime.infoMessage = "";
    persistChatState();
    renderChat(lastSnapshot);
  });
  els.chatThreadStrip.appendChild(createButton);
}

function renderChatModelPicker(thread, options, snapshot) {
  els.chatModelSelect.innerHTML = "";

  if (!options.length) {
    const emptyOption = document.createElement("option");
    emptyOption.value = "";
    emptyOption.textContent = t("chat.model.waitingOption");
    els.chatModelSelect.appendChild(emptyOption);
    els.chatModelSelect.disabled = true;
    if (snapshot?.loaded_model_id) {
      els.chatModelNote.textContent = t("chat.thread.waitingLocal");
    } else {
      els.chatModelNote.textContent = t("chat.thread.noModel");
    }
    return;
  }

  for (const option of options) {
    const item = document.createElement("option");
    item.value = chatTargetKey(option);
    item.textContent = option.label;
    els.chatModelSelect.appendChild(item);
  }

  els.chatModelSelect.value = chatTargetKey(thread.modelTarget) || chatTargetKey(options[0]);
  els.chatModelSelect.disabled = isChatBusy();

  const selectedOption = options.find((option) => chatTargetKey(option) === els.chatModelSelect.value) || options[0];
  if (selectedOption?.provider === "network" && !snapshot?.demand?.network_bearer_token) {
    els.chatModelNote.textContent = t("chat.thread.waitingNetwork");
  } else {
    els.chatModelNote.textContent = selectedOption?.note || t("chat.model.note");
  }
}

function appendChatBubble(container, role, text, metaContent = null, extraClass = "") {
  const row = document.createElement("div");
  row.className = `chat-message chat-message-${role}`;

  const bubble = document.createElement("div");
  bubble.className = "chat-bubble";
  if (extraClass) {
    bubble.classList.add(extraClass);
  }
  bubble.textContent = text;

  if (typeof metaContent === "string" && metaContent) {
    const meta = document.createElement("div");
    meta.className = "chat-bubble-meta";
    meta.textContent = metaContent;
    bubble.appendChild(meta);
  } else if (metaContent instanceof Node) {
    bubble.appendChild(metaContent);
  }

  row.appendChild(bubble);
  container.appendChild(row);
}

function renderChatTranscript(thread) {
  els.chatTranscript.innerHTML = "";
  const draft = chatRuntime.inFlight?.threadId === thread.id ? chatRuntime.inFlight.assistantText : "";
  const interrupted = !isChatBusy() ? currentInterruptedDraft(thread.id) : "";

  if (!thread.messages.length && !draft && !interrupted) {
    const empty = document.createElement("div");
    empty.className = "chat-empty";
    empty.textContent = t("chat.thread.empty");
    els.chatTranscript.appendChild(empty);
    return;
  }

  for (const message of thread.messages) {
    appendChatBubble(
      els.chatTranscript,
      message.role,
      message.content,
      buildChatMessageMetaNode(message)
    );
  }

  if (draft || (chatRuntime.inFlight?.threadId === thread.id && !draft)) {
    const draftMeta = draft
      ? buildChatMetaNode({
          role: "assistant",
          tokenCount: chatRuntime.inFlight?.completionTokens ?? estimateChatTextTokens(draft),
          tokenEstimated: chatRuntime.inFlight?.completionTokensEstimated ?? true,
          quotedCostCredits: quoteChatCostCredits(
            chatRuntime.inFlight?.modelTarget,
            "assistant",
            chatRuntime.inFlight?.completionTokens ?? estimateChatTextTokens(draft)
          ),
          billedCostCredits: chatRuntime.inFlight?.modelTarget?.provider === "local"
            ? 0
            : quoteChatCostCredits(
                chatRuntime.inFlight?.modelTarget,
                "assistant",
                chatRuntime.inFlight?.completionTokens ?? estimateChatTextTokens(draft)
              ),
          costEstimated: chatRuntime.inFlight?.completionTokensEstimated ?? true,
          costFree: chatRuntime.inFlight?.modelTarget?.provider === "local",
        })
      : null;
    appendChatBubble(
      els.chatTranscript,
      "assistant",
      draft || t("chat.thread.pending"),
      draftMeta
    );
  }

  if (interrupted) {
    const interruptedMeta = [
      formatChatUsageMeta("assistant", estimateChatTextTokens(interrupted), true),
      t("chat.thread.interrupted"),
    ]
      .filter(Boolean)
      .join(" · ");
    appendChatBubble(
      els.chatTranscript,
      "assistant",
      interrupted,
      interruptedMeta,
      "is-interrupted"
    );
  }

  window.requestAnimationFrame(() => {
    els.chatTranscript.scrollTop = els.chatTranscript.scrollHeight;
  });
}

function renderChat(snapshot = lastSnapshot) {
  const { thread, options } = reconcileChatState(snapshot);
  renderChatThreadStrip(thread);
  renderChatModelPicker(thread, options, snapshot);
  renderChatStatus();
  renderChatTranscript(thread);

  const activeOption = options.find((option) => chatTargetKey(option) === chatTargetKey(thread.modelTarget)) || options[0] || null;
  const inputText = els.chatInput.value.trim();
  const networkBlocked = activeOption?.provider === "network" && !snapshot?.demand?.network_bearer_token;
  const canSend = !isChatBusy() && Boolean(activeOption) && !networkBlocked && inputText.length > 0;

  els.chatSendButton.disabled = !canSend;
}

async function streamChatCompletion(payload) {
  const body = CHAT_TRANSPORT === "openai"
    ? {
        model: payload.model,
        messages: payload.messages,
        temperature: payload.temperature,
        max_tokens: payload.max_tokens,
        stream: payload.stream,
        stream_options: {
          include_usage: true,
          ...(payload.stream_options || {}),
        },
      }
    : payload;

  const response = await apiFetch(ROUTES.chatCompletions, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Accept: "text/event-stream",
    },
    body: JSON.stringify(body),
  });

  if (!response.ok) {
    const errorPayload = await response.json().catch(() => ({}));
    throw new Error(errorPayload.error || `Chat request failed: ${response.status}`);
  }

  if (!response.body) {
    throw new Error("Chat stream was not available.");
  }

  const decoder = new TextDecoder();
  const reader = response.body.getReader();
  let buffer = "";
  let sawDone = false;
  let usage = null;

  while (true) {
    const { value, done } = await reader.read();
    if (done) {
      break;
    }

    buffer += decoder.decode(value, { stream: true });
    buffer = buffer.replace(/\r/g, "");

    let boundary = buffer.indexOf("\n\n");
    while (boundary !== -1) {
      const rawEvent = buffer.slice(0, boundary);
      buffer = buffer.slice(boundary + 2);

      const data = rawEvent
        .split("\n")
        .filter((line) => line.startsWith("data:"))
        .map((line) => line.slice(5).trimStart())
        .join("\n");

      if (data === "[DONE]") {
        sawDone = true;
        return;
      }

      if (data) {
        const payload = JSON.parse(data);
        const nextUsage = parseChatUsage(payload?.usage);
        if (nextUsage) {
          usage = {
            promptTokens: nextUsage.promptTokens ?? usage?.promptTokens ?? null,
            completionTokens: nextUsage.completionTokens ?? usage?.completionTokens ?? null,
          };
          if (chatRuntime.inFlight) {
            if (usage.promptTokens != null) {
              chatRuntime.inFlight.promptTokens = usage.promptTokens;
              chatRuntime.inFlight.promptTokensEstimated = false;
            }
            if (usage.completionTokens != null) {
              chatRuntime.inFlight.completionTokens = usage.completionTokens;
              chatRuntime.inFlight.completionTokensEstimated = false;
            }
            renderChat(lastSnapshot);
          }
        }
        const delta = payload?.choices?.[0]?.delta?.content;
        if (typeof delta === "string" && delta) {
          chatRuntime.inFlight.assistantText += delta;
          if (chatRuntime.inFlight && usage?.completionTokens == null) {
            chatRuntime.inFlight.completionTokens = estimateChatTextTokens(chatRuntime.inFlight.assistantText);
            chatRuntime.inFlight.completionTokensEstimated = true;
          }
          renderChat(lastSnapshot);
        }
      }

      boundary = buffer.indexOf("\n\n");
    }
  }

  if (!sawDone) {
    throw new Error(t("chat.thread.streamInterrupted"));
  }

  return usage;
}

async function sendChatMessage() {
  const thread = selectedChatThread();
  const input = els.chatInput.value.trim();
  if (!thread || !input || isChatBusy()) {
    return;
  }

  const { options } = reconcileChatState(lastSnapshot, false);
  const activeOption = options.find((option) => chatTargetKey(option) === chatTargetKey(thread.modelTarget)) || options[0] || null;
  if (!activeOption) {
    chatRuntime.errorMessage = t("chat.thread.noModel");
    renderChat(lastSnapshot);
    return;
  }
  if (activeOption.provider === "network" && !lastSnapshot?.demand?.network_bearer_token) {
    chatRuntime.errorMessage = t("chat.thread.waitingNetwork");
    renderChat(lastSnapshot);
    return;
  }

  chatRuntime.errorMessage = "";
  chatRuntime.infoMessage = "";
  delete chatRuntime.interruptedDrafts[thread.id];

  const userMessagesBefore = thread.messages.filter((message) => message.role === "user").length;
  const userMessage = {
    id: createId(),
    role: "user",
    content: input,
    createdAt: Date.now(),
    tokenCount: null,
    tokenEstimated: false,
    quotedCostCredits: null,
    billedCostCredits: null,
    costEstimated: false,
    costFree: activeOption.provider === "local",
  };
  thread.messages.push(userMessage);
  if (userMessagesBefore === 0) {
    thread.title = normalizeThreadTitle(input);
  }
  thread.updatedAt = Date.now();
  const requestMessages = thread.messages.map((message) => ({
    role: message.role,
    content: message.content,
  }));
  userMessage.tokenCount = estimateChatPromptTokens(requestMessages);
  userMessage.tokenEstimated = true;
  userMessage.quotedCostCredits = quoteChatCostCredits(activeOption, "user", userMessage.tokenCount);
  userMessage.billedCostCredits = activeOption.provider === "local" ? 0 : userMessage.quotedCostCredits;
  userMessage.costEstimated = true;
  persistChatState();

  els.chatInput.value = "";
  chatRuntime.inFlight = {
    threadId: thread.id,
    assistantText: "",
    modelTarget: { provider: activeOption.provider, modelId: activeOption.modelId },
    promptTokens: userMessage.tokenCount,
    promptTokensEstimated: true,
    completionTokens: null,
    completionTokensEstimated: true,
  };
  renderChat(lastSnapshot);

  try {
    await streamChatCompletion({
      provider: activeOption.provider,
      model: activeOption.modelId,
      messages: requestMessages,
      temperature: 0.7,
      max_tokens: 1024,
      stream: true,
    });

    const inFlight = chatRuntime.inFlight;
    const finalText = inFlight?.assistantText || "";
    const promptTokenCount = normalizeTokenCount(inFlight?.promptTokens);
    if (promptTokenCount != null && promptTokenCount > 0) {
      userMessage.tokenCount = promptTokenCount;
      userMessage.tokenEstimated = Boolean(inFlight?.promptTokensEstimated);
      userMessage.quotedCostCredits = quoteChatCostCredits(activeOption, "user", promptTokenCount);
      userMessage.billedCostCredits = activeOption.provider === "local" ? 0 : userMessage.quotedCostCredits;
      userMessage.costEstimated = Boolean(inFlight?.promptTokensEstimated);
    }
    if (finalText) {
      const completionTokenCount = normalizeTokenCount(inFlight?.completionTokens);
      const assistantTokenCount = completionTokenCount != null && completionTokenCount > 0
        ? completionTokenCount
        : estimateChatTextTokens(finalText);
      const assistantTokenEstimated = completionTokenCount != null && completionTokenCount > 0
        ? Boolean(inFlight?.completionTokensEstimated)
        : true;
      const assistantQuotedCostCredits = quoteChatCostCredits(activeOption, "assistant", assistantTokenCount);
      thread.messages.push({
        id: createId(),
        role: "assistant",
        content: finalText,
        createdAt: Date.now(),
        tokenCount: assistantTokenCount,
        tokenEstimated: assistantTokenEstimated,
        quotedCostCredits: assistantQuotedCostCredits,
        billedCostCredits: activeOption.provider === "local" ? 0 : assistantQuotedCostCredits,
        costEstimated: assistantTokenEstimated,
        costFree: activeOption.provider === "local",
      });
      thread.updatedAt = Date.now();
    }

    persistChatState();
    chatRuntime.inFlight = null;
    renderChat(lastSnapshot);
  } catch (error) {
    const inFlight = chatRuntime.inFlight;
    const partial = inFlight?.assistantText || "";
    const promptTokenCount = normalizeTokenCount(inFlight?.promptTokens);
    if (promptTokenCount != null && promptTokenCount > 0) {
      userMessage.tokenCount = promptTokenCount;
      userMessage.tokenEstimated = Boolean(inFlight?.promptTokensEstimated);
      userMessage.quotedCostCredits = quoteChatCostCredits(activeOption, "user", promptTokenCount);
      userMessage.billedCostCredits = activeOption.provider === "local" ? 0 : userMessage.quotedCostCredits;
      userMessage.costEstimated = Boolean(inFlight?.promptTokensEstimated);
    }
    persistChatState();
    chatRuntime.inFlight = null;
    if (partial) {
      chatRuntime.interruptedDrafts[thread.id] = partial;
    }
    chatRuntime.errorMessage = error.message || t("chat.thread.streamInterrupted");
    renderChat(lastSnapshot);
  }
}

function renderHomeNetworkStats() {
  if (!networkStats) {
    const placeholder = networkStatsError ? "Unavailable" : "Loading...";
    els.homeNetworkDevices.textContent = placeholder;
    els.homeNetworkRam.textContent = placeholder;
    els.homeNetworkModels.textContent = placeholder;
    els.homeNetworkTtft.textContent = placeholder;
    els.homeNetworkTps.textContent = placeholder;
    els.homeNetworkEarned.textContent = placeholder;
    els.homeNetworkSpent.textContent = placeholder;
    els.homeNetworkUsdc.textContent = placeholder;
    return;
  }

  els.homeNetworkDevices.textContent = formatCredits(networkStats.total_devices ?? 0);
  els.homeNetworkRam.textContent = formatRamGB(networkStats.total_ram_gb);
  els.homeNetworkModels.textContent = formatCredits(networkStats.total_models ?? 0);
  els.homeNetworkTtft.textContent = formatMs(networkStats.avg_ttft_ms);
  els.homeNetworkTps.textContent = formatTps(networkStats.avg_tps);
  els.homeNetworkEarned.textContent = formatDisplayCredits(networkStats.total_credits_earned ?? 0, true);
  els.homeNetworkSpent.textContent = formatDisplayCredits(networkStats.total_credits_spent ?? 0, true);
  els.homeNetworkUsdc.textContent = `${formatUsdc(networkStats.total_usdc_distributed_cents ?? 0)} USDC`;
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
  if (!demand?.network_base_url) {
    return "Waiting for the gateway base URL...";
  }
  if (!model?.id) {
    return "Waiting for gateway models...";
  }
  return [
    `curl ${demand.network_base_url}/chat/completions \\`,
    `  -H "Authorization: Bearer $TEALE_API_KEY" \\`,
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

function authTrace(message) {
  console.log(`[auth] ${message}`);
  postNativeMessage({ type: "authLog", message });
}

async function withTimeout(promise, ms, label) {
  let timer = null;
  try {
    return await Promise.race([
      promise,
      new Promise((_, reject) => {
        timer = window.setTimeout(() => {
          reject(new Error(`${label} timed out after ${Math.round(ms / 1000)}s`));
        }, ms);
      }),
    ]);
  } finally {
    if (timer) {
      window.clearTimeout(timer);
    }
  }
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
  const res = await apiFetch(path, init);
  if (!res.ok) {
    const payload = await res.json().catch(() => ({}));
    throw new Error(payload.error || `Request failed: ${res.status}`);
  }
  return res.json();
}

async function getJson(path) {
  const res = await apiFetch(path);
  if (!res.ok) {
    const payload = await res.json().catch(() => ({}));
    throw new Error(payload.error || `Request failed: ${res.status}`);
  }
  return res.json();
}

async function getJsonMaybeMissing(path) {
  const res = await apiFetch(path);
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
  if (view === "home") {
    renderChat(lastSnapshot);
    refreshNetworkStats().catch((error) => {
      console.error("network stats refresh failed", error);
    });
    refreshNetworkModels().catch((error) => {
      console.error("home chat model refresh failed", error);
    });
  }
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
  maybeFallbackToBundledApp(error);
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
  networkStatsError = friendlyError(error);
  renderHomeNetworkStats();

  els.supplyEarningRate.textContent = "Waiting for a loaded model...";
  els.supplySessionCredits.textContent = "0";
  els.supplyWalletBalance.textContent = t("common.waitingLocalService");

  els.localBaseUrl.textContent = "-";
  els.localModelId.textContent = t("common.noModelLoaded");
  els.localCurl.textContent = "Waiting for a local model...";
  els.networkBaseUrl.textContent = "-";
  els.networkToken.textContent = t("common.syncing");
  els.networkToken.title = "Copy device bearer";
  els.networkToken.disabled = true;
  els.networkTokenCopy.textContent = "Copy device bearer";
  els.networkSelectedModel.textContent = "Waiting for gateway models...";
  els.networkTokenNote.textContent = "The rotating device bearer is for app transport and debugging. Use a human-account API key for persistent direct gateway clients.";
  els.networkCurl.textContent = "Waiting for gateway models...";
  els.networkModelTableBody.innerHTML = "";
  els.networkModelEmpty.textContent = "The network model table appears once Teale responds locally.";

  els.walletDeviceName.textContent = "-";
  els.walletDeviceId.textContent = "-";
  els.walletDeviceId.title = "Copy device ID";
  els.walletStatus.textContent = "Offline";
  els.walletModel.textContent = t("common.noModelLoaded");
  els.walletBalance.textContent = t("common.waitingLocalService");
  els.walletUsdc.textContent = "0.00";
  els.walletSince.textContent = "Not serving yet";
  els.walletRate.textContent = "Availability earnings begin once a compatible model is loaded and serving.";
  els.walletNote.textContent = "The companion will sync the device wallet once Teale responds locally.";
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

  if (recommended.loaded) {
    els.recommendedAction.textContent = snapshot.service_state === "serving"
      ? t("model.action.servingNow")
      : t("model.action.loaded");
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
        await post(ROUTES.modelLoad, { model: recommended.id });
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
      await post(ROUTES.modelDownload, { model: recommended.id });
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
          await post(ROUTES.modelLoad, { model: model.id });
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
          await post(ROUTES.modelDownload, { model: model.id });
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
  const visibleModels = visibleNetworkModels();
  if (!visibleModels.length) {
    els.networkModelEmpty.textContent = "No live gateway model data yet.";
    return;
  }

  const sorted = sortModels(visibleModels);
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
      formatPricePerMillionDisplay(model.prompt),
      formatPricePerMillionDisplay(model.completion),
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
    title.textContent = entry.type === "AVAILABILITY_SESSION"
      ? "Availability session"
      : entry.type;
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
    amount.textContent = `${entry.amount < 0 ? "-" : "+"}${formatDisplayCredits(Math.abs(entry.amount), true)}`;

    row.append(info, amount);
    els.ledgerList.appendChild(row);
  }
}

function renderAccountWallet() {
  if (accountSummary) {
    els.accountWalletBalance.textContent = formatDisplayCredits(accountSummary.balance_credits ?? 0, false);
    els.accountWalletUsdc.textContent = formatUsdc(accountSummary.usdc_cents ?? 0);
    els.accountWalletNote.textContent = t("account.wallet.note.summary");
    return;
  }

  if (authUser || authSession?.user?.id) {
    els.accountWalletBalance.textContent = formatDisplayCredits(0, false);
    els.accountWalletUsdc.textContent = "0.00";
    els.accountWalletNote.textContent = t("account.wallet.note.pending", {
      fallback: "Account wallet starts at 0 until device balances are swept here.",
    });
    return;
  }

  els.accountWalletBalance.textContent = "-";
  els.accountWalletUsdc.textContent = "0.00";
  els.accountWalletNote.textContent = t("account.wallet.note.signedOut");
}

function renderAccountApiKeys() {
  const signedIn = Boolean(authUser);
  const linked = Boolean(accountSummary?.account_user_id);

  els.accountApiKeyNote.textContent = "Create revocable API keys for direct demand traffic to gateway.teale.com, including Claude Desktop 3P and Claude Code gateway mode. These keys belong to your human account and stay valid until you revoke them.";
  els.accountApiKeyLabel.disabled = !signedIn || !linked || accountApiKeyCreateInFlight;
  els.accountApiKeyCreate.disabled = !signedIn || !linked || accountApiKeyCreateInFlight;
  if (accountApiKeyCreateInFlight) {
    setBusyButton(els.accountApiKeyCreate, "Create API key");
  } else {
    els.accountApiKeyCreate.textContent = "Create API key";
  }

  els.accountApiKeyCreatedWrap.hidden = !createdAccountApiKeyToken;
  els.accountApiKeyCreated.textContent = createdAccountApiKeyToken || "";

  els.accountApiKeysList.innerHTML = "";
  els.accountApiKeysEmpty.hidden = true;

  if (!signedIn) {
    els.accountApiKeysEmpty.hidden = false;
    els.accountApiKeysEmpty.textContent = "Sign in to manage direct gateway API keys.";
  } else if (!linked) {
    els.accountApiKeysEmpty.hidden = false;
    els.accountApiKeysEmpty.textContent = "Account API keys appear after this signed-in device is linked to the gateway account wallet.";
  } else if (!accountApiKeys.length) {
    els.accountApiKeysEmpty.hidden = false;
    els.accountApiKeysEmpty.textContent = "No direct gateway API keys created yet.";
  } else {
    for (const key of accountApiKeys) {
      const row = document.createElement("article");
      row.className = "ledger-row";

      const info = document.createElement("div");
      const title = document.createElement("h3");
      title.textContent = key.label || "Unnamed API key";
      const meta = document.createElement("p");
      meta.className = "ledger-meta";
      const parts = [
        key.tokenPreview || "-",
        `created ${formatTimestamp(key.createdAt)}`,
        key.lastUsedAt ? `last used ${formatTimestamp(key.lastUsedAt)}` : "never used",
      ];
      meta.textContent = parts.join(" // ");
      info.append(title, meta);

      const actionWrap = document.createElement("div");
      actionWrap.className = "actions actions-tight";
      if (key.revokedAt) {
        const revoked = document.createElement("div");
        revoked.className = "amount-negative";
        revoked.textContent = "revoked";
        actionWrap.append(revoked);
      } else {
        const revoke = document.createElement("button");
        revoke.className = "action";
        revoke.type = "button";
        revoke.disabled = accountApiKeyRevokeInFlight === key.keyID;
        if (accountApiKeyRevokeInFlight === key.keyID) {
          setBusyButton(revoke, "Revoke");
        } else {
          revoke.textContent = "Revoke";
        }
        revoke.addEventListener("click", () => {
          revokeAccountApiKey(key.keyID).catch(() => {});
        });
        actionWrap.append(revoke);
      }

      row.append(info, actionWrap);
      els.accountApiKeysList.appendChild(row);
    }
  }

  els.accountApiKeyStatus.textContent = accountApiKeyStatus || "";
  els.accountApiKeyStatus.className = accountApiKeyStatusIsError ? "error-note" : "muted";
}

function defaultDeviceSendNote() {
  if (!lastSnapshot?.wallet?.current_device_id) {
    return "Waiting for the gateway device wallet.";
  }
  if (els.sendAsset.value !== "credits") {
    return "USDC transfers are not available yet. Send Teale credits for now.";
  }
  return `Use full wallet IDs only. Send from this device wallet to a 64-char device wallet ID or a full account wallet ID. Display is in ${displayUnit === "usd" ? "USD" : "credits"}.`;
}

function defaultAccountSendNote() {
  if (!authUser && !accountSummary) {
    return t("account.wallet.note.signedOut");
  }
  if (!accountSummary) {
    return t("account.wallet.note.pending", {
      fallback: "Account wallet starts at 0 until this device is linked locally.",
    });
  }
  if (els.accountSendAsset.value !== "credits") {
    return "USDC transfers are not available yet. Send Teale credits for now.";
  }
  return `Use full wallet IDs only. Send from the account wallet to a full account wallet ID or a 64-char device wallet ID. Display is in ${displayUnit === "usd" ? "USD" : "credits"}.`;
}

function updateSendControls() {
  const deviceWallet = deviceWalletBalance();
  const deviceAmount = parseDisplayAmountToCredits(els.sendAmount.value || "");
  const deviceRecipient = els.sendRecipient.value.trim();
  const deviceCredits = deviceWallet.credits;
  const deviceCreditsSupported = els.sendAsset.value === "credits";
  const deviceCanSend = Boolean(lastSnapshot?.wallet?.current_device_id)
    && deviceCreditsSupported
    && deviceRecipient
    && Number.isInteger(deviceAmount)
    && typeof deviceCredits === "number"
    && deviceAmount > 0
    && deviceAmount <= deviceCredits;

  if (walletSendInFlight) {
    setBusyButton(els.sendSubmit, t("chat.action.send", { fallback: "Send" }));
  } else {
    els.sendSubmit.textContent = t("chat.action.send", { fallback: "Send" });
  }
  els.sendSubmit.disabled = walletSendInFlight || !deviceCanSend;
  els.sendNote.textContent = walletSendStatus || defaultDeviceSendNote();

  const accountWallet = accountWalletBalance();
  const accountAmount = parseDisplayAmountToCredits(els.accountSendAmount.value || "");
  const accountRecipient = els.accountSendRecipient.value.trim();
  const accountCredits = accountWallet.credits;
  const accountCreditsSupported = els.accountSendAsset.value === "credits";
  const accountCanSend = Boolean(accountSummary?.account_user_id)
    && accountCreditsSupported
    && accountRecipient
    && Number.isInteger(accountAmount)
    && typeof accountCredits === "number"
    && accountAmount > 0
    && accountAmount <= accountCredits;

  if (accountSendInFlight) {
    setBusyButton(els.accountSendSubmit, t("chat.action.send", { fallback: "Send" }));
  } else {
    els.accountSendSubmit.textContent = t("chat.action.send", { fallback: "Send" });
  }
  els.accountSendSubmit.disabled = accountSendInFlight || !accountCanSend;
  els.accountSendNote.textContent = accountSendStatus || defaultAccountSendNote();
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
    const key = device.wan_node_id
      || `${device.platform || "unknown"}:${(device.device_name || "unknown").toLowerCase()}`;
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

function supabaseDeviceMergeKey(device) {
  return device?.wan_node_id
    || `${device?.platform || "unknown"}:${(device?.device_name || "unknown").toLowerCase()}`;
}

function mergeSupabaseDeviceLists(...lists) {
  const merged = new Map();

  for (const list of lists) {
    for (const device of list || []) {
      if (!device) {
        continue;
      }

      const key = supabaseDeviceMergeKey(device);
      const existing = merged.get(key);
      if (!existing) {
        merged.set(key, { ...device });
        continue;
      }

      merged.set(key, {
        ...existing,
        ...device,
        id: existing.id || device.id,
        wan_node_id: existing.wan_node_id || device.wan_node_id,
        device_name: existing.device_name || device.device_name,
        platform: existing.platform || device.platform,
        chip_name: existing.chip_name || device.chip_name,
        ram_gb: existing.ram_gb ?? device.ram_gb,
        registered_at: existing.registered_at || device.registered_at,
        last_seen: normalizeSupabaseTimestamp(existing.last_seen) >= normalizeSupabaseTimestamp(device.last_seen)
          ? existing.last_seen
          : device.last_seen,
        is_active: existing.is_active ?? device.is_active,
      });
    }
  }

  return Array.from(merged.values()).sort((left, right) => (
    normalizeSupabaseTimestamp(right?.last_seen) - normalizeSupabaseTimestamp(left?.last_seen)
  ));
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
      ? formatDisplayCredits(device.walletBalance, true)
      : "-";

    const actionCell = document.createElement("td");
    const actionRow = document.createElement("div");
    actionRow.className = "actions actions-tight";

    const send = document.createElement("button");
    send.className = "action";
    send.textContent = t("account.sendToDevice", { fallback: "Send credits" });
    send.disabled = !accountSummary?.account_user_id;
    send.addEventListener("click", () => {
      els.accountSendRecipient.value = device.deviceId || "";
      accountSendStatus = "";
      updateSendControls();
      els.accountSendAmount.focus();
    });
    actionRow.append(send);

    const sweep = document.createElement("button");
    sweep.className = "action";
    sweep.textContent = t("account.device.sweep", { fallback: "Sweep" });
    sweep.disabled = !authUser || !device.sweepEnabled;
    sweep.addEventListener("click", async () => {
      try {
        const result = await post(ROUTES.accountSweep, { deviceID: device.deviceId });
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
          await post(ROUTES.accountDevicesRemove, { deviceID: device.deviceId });
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
  const linkedProviders = linkedProviderNames();
  const githubLinked = linkedProviders.includes("github");
  const googleLinked = linkedProviders.includes("google");
  const phoneLinked = linkedProviders.includes("phone");
  const githubIdentity = authIdentities.find((identity) => identity.provider === "github");
  const googleIdentity = authIdentities.find((identity) => identity.provider === "google");
  const phoneIdentity = authIdentities.find((identity) => identity.provider === "phone");
  const signedInViaPhone = Boolean(authUser?.phone || phoneIdentity || accountSummary?.phone);
  const signedInToAccount = Boolean(
    authUser?.id || authSession?.user?.id || accountSummary?.account_user_id || signedInViaPhone
  );
  const emails = linkedEmails();
  const githubUsername = linkedGithubUsername();

  els.accountId.textContent = authUser?.id || accountSummary?.account_user_id || "-";
  els.accountEmail.textContent = emails.length ? emails.join(" | ") : "-";
  if (els.accountGithub) {
    els.accountGithub.textContent = githubUsername || "-";
  }
  els.accountPhone.textContent = authUser?.phone || accountSummary?.phone || "-";
  els.accountIdentities.textContent = authIdentities.length
    ? providerLabel(authIdentities)
    : linkedProviders.map((provider) => providerDisplayName(provider)).join(" | ") || "-";
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
    els.authPhonePanel.style.display = "";
    els.authNote.textContent = t("auth.note.walletStillWorks");
    return;
  }

  if (!signedInToAccount) {
    els.authStatus.textContent = t("auth.status.notSignedIn");
    els.authUser.textContent = authErrorMessage || t("auth.user.prompt");
    els.authGithubButton.textContent = t("auth.button.signInGithub");
    els.authGithubButton.disabled = false;
    els.authGoogleButton.textContent = t("auth.button.signInGoogle");
    els.authGoogleButton.disabled = false;
    els.authPhonePanel.hidden = false;
    els.authPhonePanel.style.display = "";
    els.authPhoneSendButton.disabled = false;
    els.authPhoneVerifyButton.disabled = false;
    els.authSignoutButton.hidden = true;
    els.authNote.textContent = authErrorMessage || t("auth.note.claimsDevice");
    return;
  }

  els.authStatus.textContent = t("auth.status.signedIn");
  els.authUser.textContent = userLabel(authUser) !== t("auth.status.notSignedIn")
    ? userLabel(authUser)
    : accountSummary?.phone || accountSummary?.email || accountSummary?.account_user_id || t("auth.status.signedIn");
  els.authSignoutButton.hidden = false;
  els.authPhonePanel.hidden = true;
  els.authPhonePanel.style.display = "none";

  if (githubLinked || githubIdentity) {
    els.authGithubButton.textContent = t("auth.button.githubLinked");
    els.authGithubButton.disabled = true;
  } else {
    els.authGithubButton.textContent = t("auth.button.linkGithub");
    els.authGithubButton.disabled = false;
  }

  if (googleLinked || googleIdentity) {
    els.authGoogleButton.textContent = t("auth.button.googleLinked");
    els.authGoogleButton.disabled = true;
  } else {
    els.authGoogleButton.textContent = t("auth.button.linkGoogle");
    els.authGoogleButton.disabled = false;
  }

  if (phoneLinked || signedInViaPhone) {
    els.authNote.textContent = (githubLinked || githubIdentity) && (googleLinked || googleIdentity)
      ? t("auth.note.allLinked")
      : t("auth.note.phoneCanLink");
  } else {
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
    linkedGatewayAccountStateKey = null;
    accountDevices = [];
    accountSummary = null;
    accountApiKeys = [];
    createdAccountApiKeyToken = null;
    accountApiKeyStatus = "";
    accountApiKeyStatusIsError = false;
    supabaseAccountDevices = [];
    clearAuthErrorState();
    renderAccountWallet();
    renderAuthState();
    renderAccountApiKeys();
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
      flowType: "pkce",
    },
  });

  supabaseClient.auth.onAuthStateChange(async (_event, session) => {
    authSession = session;
    authUser = session?.user || null;
    postNativeSessionSync(session);
    if (authUser) {
      clearAuthErrorState();
    }
    linkedSupabaseUserId = authUser ? linkedSupabaseUserId : null;
    linkedGatewayAccountStateKey = authUser ? linkedGatewayAccountStateKey : null;
    await ensureSupabaseIdentity();
    await refreshAccountState();
    await ensureGatewayAccountLink();
    await refreshAccountState();
    renderAccountWallet();
    renderAccountApiKeys();
    renderAuthState();
    renderAccountDevices();
    renderHome(lastSnapshot);
  });

  const { data } = await supabaseClient.auth.getSession();
  let session = data.session;
  if (!session) {
    session = await restorePersistedSupabaseSession();
  }
  if (!session) {
    session = await applyPendingNativeSessionIfNeeded();
  }
  authSession = session;
  authUser = session?.user || null;
  postNativeSessionSync(authSession);
  await consumePendingOAuthCallback();
  if (!authSession) {
    authSession = await restorePersistedSupabaseSession();
    authUser = authSession?.user || null;
  }
  await ensureSupabaseIdentity();
  await refreshAccountState();
  await ensureGatewayAccountLink();
  await refreshAccountState();
  renderAccountWallet();
  renderAccountApiKeys();
  renderAuthState();
  renderAccountDevices();
}

async function refreshAccountState() {
  const summaryPromise = getJsonMaybeMissing(ROUTES.accountSummary).catch((error) => {
    console.warn("account summary fetch failed", error);
    return null;
  });
  const apiKeysPromise = getJsonMaybeMissing(ROUTES.accountApiKeys).catch((error) => {
    console.warn("account api key fetch failed", error);
    return null;
  });

  if (!supabaseClient || !authUser) {
    authIdentities = [];
    supabaseAccountDevices = [];
    accountSummary = await summaryPromise;
    accountDevices = accountSummary?.devices || [];
    accountApiKeys = [];
    authTrace(`account state refreshed summaryDevices=${accountDevices.length} supabaseDevices=0 auth=none`);
    return;
  }

  const [sessionState, summary, apiKeysResponse, directSupabaseDevices] = await Promise.all([
    refreshAuthoritativeAuthState("refreshAccountState"),
    summaryPromise,
    apiKeysPromise,
    supabaseClient
      .from("devices")
      .select("id,user_id,device_name,platform,chip_name,ram_gb,wan_node_id,registered_at,last_seen,is_active")
      .eq("user_id", authUser.id)
      .eq("is_active", true)
      .order("last_seen", { ascending: false })
      .then(({ data, error }) => {
        if (error) {
          throw error;
        }
        return data || [];
      })
      .catch((error) => {
        console.warn("supabase account devices fetch failed", error);
        authTrace(`supabase account devices fetch failed ${friendlyError(error)}`);
        return [];
      }),
  ]);

  accountSummary = summary;
  accountDevices = summary?.devices || [];
  accountApiKeys = apiKeysResponse?.keys || [];
  supabaseAccountDevices = mergeSupabaseDeviceLists(
    supabaseAccountDevices,
    sessionState?.devices || [],
    directSupabaseDevices || []
  );
  authTrace(
    `account state refreshed summaryDevices=${accountDevices.length} apiKeys=${accountApiKeys.length} supabaseDevices=${supabaseAccountDevices.length}`
  );
}

async function createAccountApiKey() {
  if (!authUser || !accountSummary?.account_user_id || accountApiKeyCreateInFlight) {
    return;
  }
  accountApiKeyCreateInFlight = true;
  accountApiKeyStatus = "";
  accountApiKeyStatusIsError = false;
  createdAccountApiKeyToken = null;
  renderAccountApiKeys();
  try {
    const response = await post(ROUTES.accountApiKeys, {
      label: els.accountApiKeyLabel.value.trim() || null,
    });
    createdAccountApiKeyToken = response?.token || null;
    accountApiKeyStatus = "Created a direct gateway API key for this human account.";
    const refreshed = await getJsonMaybeMissing(ROUTES.accountApiKeys);
    accountApiKeys = refreshed?.keys || [];
    els.accountApiKeyLabel.value = "";
  } catch (error) {
    accountApiKeyStatus = error.message;
    accountApiKeyStatusIsError = true;
  } finally {
    accountApiKeyCreateInFlight = false;
    renderAccountApiKeys();
  }
}

async function revokeAccountApiKey(keyId) {
  if (!keyId || accountApiKeyRevokeInFlight === keyId) {
    return;
  }
  accountApiKeyRevokeInFlight = keyId;
  accountApiKeyStatus = "";
  accountApiKeyStatusIsError = false;
  renderAccountApiKeys();
  try {
    await post(ROUTES.accountApiKeysRevoke, { keyID: keyId });
    const refreshed = await getJsonMaybeMissing(ROUTES.accountApiKeys);
    accountApiKeys = refreshed?.keys || [];
    accountApiKeyStatus = "Revoked the direct gateway API key.";
  } catch (error) {
    accountApiKeyStatus = error.message;
    accountApiKeyStatusIsError = true;
    throw error;
  } finally {
    accountApiKeyRevokeInFlight = null;
    renderAccountApiKeys();
  }
}

async function refreshAuthoritativeAuthState(reason, { throwOnError = false } = {}) {
  if (!authSession?.access_token) {
    authTrace(`local auth session skipped reason=${reason} missing access token`);
    return null;
  }

  try {
    const sessionState = await post(ROUTES.authSession, {
      accessToken: authSession.access_token,
    });
    const identities = sessionState?.identities || sessionState?.user?.identities || [];
    if (sessionState?.user) {
      authUser = {
        ...(authUser || {}),
        ...sessionState.user,
        identities,
      };
    }
    authIdentities = identities;
    supabaseAccountDevices = mergeSupabaseDeviceLists(supabaseAccountDevices, sessionState?.devices || []);
    authTrace(
      `local auth session success reason=${reason} providers=${identities.map((identity) => identity.provider).join(",") || "none"} devices=${supabaseAccountDevices.length}`
    );
    return sessionState;
  } catch (error) {
    authTrace(`local auth session failed reason=${reason} error=${error.message}`);
    if (throwOnError) {
      throw error;
    }
    return null;
  }
}

async function reconcileAlreadyLinkedIdentity() {
  const provider = loadPendingOAuthProvider();
  authTrace(`reconcile already linked provider=${provider || "unknown"}`);
  if (oauthReconcileInFlight) {
    authTrace("reconcile skipped because another reconcile is already in flight");
    return false;
  }
  oauthReconcileInFlight = true;

  try {
    try {
      await refreshAuthoritativeAuthState("reconcileAlreadyLinkedIdentity", { throwOnError: true });
    } catch (error) {
      authTrace(`reconcile authoritative refresh threw ${error.message}`);
    }

    await refreshAccountState();

    if (provider && authIdentities.some((identity) => identity.provider === provider)) {
      clearAuthErrorState();
      linkedGatewayAccountStateKey = null;
      await ensureGatewayAccountLink();
      await refreshAccountState();
      authTrace(`reconcile success provider=${provider}`);
      clearPendingOAuthProvider();
      return true;
    }

    authTrace(
      `reconcile unresolved provider=${provider || "unknown"} providers=${authIdentities.map((identity) => identity.provider).join(",") || "none"}`
    );
    return false;
  } finally {
    oauthReconcileInFlight = false;
  }
}

async function consumePendingOAuthCallback() {
  if (oauthCallbackExchangeInFlight) {
    authTrace("consume callback skipped because an auth exchange is already in flight");
    return;
  }
  const callbackUrl = loadStoredOAuthCallback();
  if (!callbackUrl || !supabaseClient) {
    return;
  }
  oauthCallbackExchangeInFlight = true;
  try {
    authTrace(`consume callback ${summarizeCallbackUrl(callbackUrl)}`);
    const params = callbackParams(callbackUrl);
    const oauthError =
      callbackValue(params, "error_description") ||
      callbackValue(params, "error") ||
      callbackValue(params, "error_code");
    if (oauthError) {
      const normalizedOauthError = String(oauthError || "").normalize("NFKC").toLowerCase();
      authTrace(`callback oauth error ${oauthError}`);
      authTrace(`callback oauth error normalized=${normalizedOauthError}`);
      if (
        authUser &&
        (
          normalizedOauthError.includes("already linked") ||
          (normalizedOauthError.includes("identity") && normalizedOauthError.includes("linked"))
        )
      ) {
        authTrace("callback oauth error entering already-linked reconcile path");
        clearStoredOAuthCallback();
        const reconciled = await reconcileAlreadyLinkedIdentity();
        if (!reconciled) {
          const provider = loadPendingOAuthProvider();
          setAuthErrorState(
            provider
              ? `${providerDisplayName(provider)} is already linked, but Supabase did not return it on this current session.`
              : "Identity is already linked, but it did not appear on this current session."
          );
          clearPendingOAuthProvider();
        }
        return;
      }
      setAuthErrorState(authConfigHintFromMessage(oauthError));
      clearStoredOAuthCallback();
      clearPendingOAuthProvider();
      return;
    }

    const accessToken = callbackValue(params, "access_token");
    const refreshToken = callbackValue(params, "refresh_token");
    if (accessToken && refreshToken) {
      try {
        authTrace("setSession from callback tokens");
        const { data, error } = await withTimeout(
          supabaseClient.auth.setSession({
            access_token: accessToken,
            refresh_token: refreshToken,
          }),
          15000,
          "setSession"
        );
        if (error) {
          throw error;
        }
        authTrace(`setSession success user=${data.session?.user?.id || "none"}`);
        authSession = data.session;
        authUser = data.session?.user || null;
        clearAuthErrorState();
        linkedGatewayAccountStateKey = null;
        clearStoredOAuthCallback();
        clearPendingOAuthProvider();
        window.history.replaceState({}, "", "teale://localhost/");
      } catch (error) {
        authTrace(`setSession failed ${error.message}`);
        setAuthErrorState(authConfigHintFromMessage(error.message));
        clearStoredOAuthCallback();
        clearPendingOAuthProvider();
      }
      return;
    }

    const code = callbackValue(params, "code");
    if (!code) {
      authTrace("callback missing code and tokens");
      clearStoredOAuthCallback();
      clearPendingOAuthProvider();
      return;
    }
    try {
      authTrace("exchangeCodeForSession start");
      const { data, error } = await withTimeout(
        supabaseClient.auth.exchangeCodeForSession(code),
        15000,
        "exchangeCodeForSession"
      );
      if (error) {
        throw error;
      }
      authTrace(`exchangeCodeForSession success user=${data.session?.user?.id || "none"}`);
      authSession = data.session;
      authUser = data.session?.user || null;
      clearAuthErrorState();
      linkedGatewayAccountStateKey = null;
      clearStoredOAuthCallback();
      clearPendingOAuthProvider();
      window.history.replaceState({}, "", "teale://localhost/");
    } catch (error) {
      authTrace(`exchangeCodeForSession failed ${error.message}`);
      setAuthErrorState(authConfigHintFromMessage(error.message));
      clearStoredOAuthCallback();
      clearPendingOAuthProvider();
    }
  } finally {
    oauthCallbackExchangeInFlight = false;
  }
}

async function ensureSupabaseIdentity() {
  if (!supabaseClient || !authUser || !lastSnapshot?.device) {
    return;
  }
  if (linkedSupabaseUserId === authUser.id) {
    return;
  }

  const profilePayload = {
    id: authUser.id,
    display_name: userDisplayName(authUser),
    phone: authUser.phone || null,
    email: authUser.email || null,
  };

  const { error: profileError } = await supabaseClient.from("profiles").upsert(profilePayload, { onConflict: "id" });
  if (profileError) {
    throw profileError;
  }

  const device = lastSnapshot.device || {};
  const hardware = device.hardware || {};
  const deviceName = device.display_name || DESKTOP_DEVICE_LABEL;
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
      .eq("platform", DESKTOP_PLATFORM)
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
    platform: DESKTOP_PLATFORM,
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

  let identities = authIdentities;
  if (!identities.length) {
    try {
      const authoritative = await refreshAuthoritativeAuthState("ensureGatewayAccountLink", { throwOnError: true });
      identities = authoritative?.identities || authUser.identities || [];
      authIdentities = identities;
    } catch (error) {
      console.warn("authoritative identity refresh failed", error);
    }
  }

  const primaryEmail = primaryLinkedEmail() || authUser.email || null;
  const githubUsername = linkedGithubUsername();
  const stateKey = accountLinkStateKey(authUser, identities);
  const needsMetadataBackfill = Boolean(
    accountSummary?.account_user_id === authUser.id &&
    (
      (primaryEmail && !accountSummary?.email) ||
      (githubUsername && !accountSummary?.github_username)
    )
  );
  if (!stateKey || (linkedGatewayAccountStateKey === stateKey && !needsMetadataBackfill)) {
    return;
  }

  const payload = {
    accountUserID: authUser.id,
    displayName: userDisplayName(authUser),
    phone: authUser.phone || null,
    email: primaryEmail,
    githubUsername: githubUsername,
  };

  try {
    accountSummary = await post(ROUTES.accountLink, payload);
    authTrace(
      `gateway account link success providers=${authIdentities.map((identity) => identity.provider).join(",") || "none"} github=${payload.githubUsername || "none"}`
    );
    linkedGatewayAccountStateKey = stateKey;
  } catch (error) {
    authTrace(`gateway account link failed ${error.message}`);
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
  clearAuthErrorState();
  setPendingOAuthProvider(provider);
  authTrace(`startOAuth provider=${provider} signedIn=${Boolean(authUser)}`);
  const redirectUrl = lastSnapshot.auth.redirect_url || "teale://auth/callback";
  const options = {
    redirectTo: redirectUrl,
    skipBrowserRedirect: true,
  };
  if (provider === "github") {
    options.scopes = "user:email";
  }
  if (provider === "google") {
    options.scopes = "email profile";
    options.queryParams = {
      access_type: "offline",
      prompt: "select_account",
    };
  }
  try {
    let response;
    if (authUser) {
      response = await supabaseClient.auth.linkIdentity({
        provider,
        options,
      });
    } else {
      response = await supabaseClient.auth.signInWithOAuth({
        provider,
        options,
      });
    }

    if (response.error) {
      throw response.error;
    }
    if (!response.data?.url) {
      throw new Error(`${providerDisplayName(provider)} sign-in URL was not returned.`);
    }
    const oauthConfigError = oauthMisconfigFromUrl(provider, response.data.url);
    if (oauthConfigError) {
      throw new Error(oauthConfigError);
    }
    authTrace(`startOAuth url ready provider=${provider}`);
    if (!postNativeMessage({ type: "openExternal", url: response.data.url })) {
      window.open(response.data.url, "_blank", "noopener,noreferrer");
    }
  } catch (error) {
    authTrace(`startOAuth failed provider=${provider} error=${error.message}`);
    alert(authConfigHint(provider, error.message));
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
    const models = await getJson(ROUTES.networkModels);
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
    renderChat(lastSnapshot);
  } catch (error) {
    console.error(error);
    networkModels = [];
    els.networkModelTableBody.innerHTML = "";
    els.networkModelEmpty.textContent = "Could not load live gateway models yet.";
    renderChat(lastSnapshot);
  }
}

async function refreshNetworkStats(force = false) {
  if (!lastSnapshot) {
    return;
  }
  const now = Date.now();
  if (!force && now - networkStatsFetchedAt < 15_000) {
    return;
  }
  try {
    networkStats = await getJson(ROUTES.networkStats);
    networkStatsError = null;
    networkStatsFetchedAt = now;
    renderHomeNetworkStats();
  } catch (error) {
    console.error("network stats refresh failed", error);
    networkStatsError = error.message || friendlyError(error);
    renderHomeNetworkStats();
  }
}

function maybeFallbackToBundledApp(error) {
  if (!SHELL_MODE || bundledFallbackAttempted) {
    return;
  }
  if (!ROUTES.bundledApp || !window.location.protocol.startsWith("http")) {
    return;
  }
  const message = friendlyError(error).toLowerCase();
  const looksLikeLocalBridgeFailure = message.includes("failed to fetch")
    || message.includes("networkerror")
    || message.includes("load failed")
    || message.includes("blocked")
    || message.includes("status failed");
  if (!looksLikeLocalBridgeFailure || consecutiveSnapshotFailures < 3) {
    return;
  }
  bundledFallbackAttempted = true;
  window.location.replace(ROUTES.bundledApp);
}

function renderHome(snapshot) {
  const walletView = deviceWalletBalance();
  els.homeStatus.textContent = labelForState(snapshot?.service_state);
  els.homeModel.textContent = snapshot?.loaded_model_id || "No model loaded";
  els.homeBalance.textContent = walletView.credits != null
    ? formatDisplayCredits(walletView.credits, true)
    : "Syncing...";
  els.homeAccount.textContent = userLabel(authUser);
  renderHomeNetworkStats();
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
  els.supplySessionCredits.textContent = formatDisplayCredits(wallet.estimated_session_credits ?? 0, true);
  els.supplyWalletBalance.textContent = deviceWalletBalance().credits != null
    ? formatDisplayCredits(deviceWalletBalance().credits, true)
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
  els.networkToken.title = demand.network_bearer_token
    ? "Click to copy device bearer"
    : "Copy device bearer";
  els.networkToken.disabled = !demand.network_bearer_token;
  els.networkTokenCopy.textContent = t("demand.action.copyDeviceBearer", { fallback: "Copy device bearer" });
  els.networkTokenNote.textContent = demand.network_bearer_token
      ? "This rotating device bearer is for Teale app transport and debugging. Use a human-account API key from Account for persistent direct gateway clients."
      : "Waiting for the device bearer token from the gateway wallet sync.";
  els.networkSelectedModel.textContent = selected ? selected.id : t("demand.selected.waiting", { fallback: "Waiting for gateway models..." });
  els.networkCurl.textContent = buildNetworkCurl(demand, selected);
  renderNetworkModels();
}

function renderWallet(snapshot) {
  const walletView = deviceWalletBalance();
  const wallet = snapshot.wallet || {};
  els.walletDeviceName.textContent = snapshot.device?.display_name || "-";
  els.walletDeviceId.textContent = truncateDeviceId(wallet.current_device_id || "-");
  els.walletDeviceId.title = wallet.current_device_id || "Copy device ID";
  els.walletStatus.textContent = labelForState(snapshot.service_state);
  els.walletModel.textContent = snapshot.loaded_model_id || t("common.noModelLoaded");
  els.walletBalance.textContent = walletView.credits != null
    ? formatDisplayCredits(walletView.credits, false)
    : wallet.gateway_sync_error
      ? "Retrying sync"
      : "Syncing...";
  els.walletUsdc.textContent = formatUsdc(walletView.usdcCents ?? 0);
  els.walletSince.textContent = formatRelativeFromUnix(wallet.supplying_since);
  els.walletRate.textContent = availabilityRateLabel(wallet);
  els.walletNote.textContent = walletView.note;
  renderLedger(walletView.transactions);
}

function render(snapshot) {
  lastSnapshot = snapshot;
  if (walletRefreshInFlight) {
    setBusyButton(els.headerRefresh, t("wallet.action.refreshing", { fallback: "Refreshing..." }));
  } else {
    els.headerRefresh.innerHTML = `
      <svg viewBox="0 0 24 24" aria-hidden="true">
        <path d="M12 4.75a7.25 7.25 0 0 1 6.86 4.95h-2.61a.75.75 0 0 0 0 1.5H21a.75.75 0 0 0 .75-.75V5.7a.75.75 0 0 0-1.5 0v2.13A8.75 8.75 0 1 0 20.75 12a.75.75 0 0 0-1.5 0A7.25 7.25 0 1 1 12 4.75Z"></path>
      </svg>`
      ;
  }
  els.headerRefresh.disabled = walletRefreshInFlight || !snapshot?.wallet?.current_device_id;
  renderPrivacyFilter(snapshot);
  renderHome(snapshot);
  renderSupply(snapshot);
  renderDemand(snapshot);
  renderChat(snapshot);
  renderWallet(snapshot);
  renderAccountWallet();
  renderAccountApiKeys();
  updateSendControls();
  renderAuthState();
  renderAccountDevices();
}

async function refresh() {
  const res = await apiFetch(ROUTES.snapshot);
  if (!res.ok) {
    throw new Error(`Teale status failed: ${res.status}`);
  }
  const snapshot = await res.json();
  consecutiveSnapshotFailures = 0;
  reconcilePendingAction(snapshot);
  lastSnapshot = snapshot;
  await ensureAuthClient(snapshot.auth);
  await syncNativePendingOAuthCallback();
  if (pendingOAuthCallbackUrl) {
    await consumePendingOAuthCallback();
    await refreshAccountState();
    await ensureGatewayAccountLink();
    await refreshAccountState();
  }
  render(snapshot);
  if (activeView === "home") {
    await refreshNetworkStats();
    await refreshNetworkModels();
  }
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
    refresh().catch((error) => {
      consecutiveSnapshotFailures += 1;
      setDisconnected(error);
    });
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
    await post(ROUTES.modelUnload);
    await refresh();
  } catch (error) {
    clearBusyAction();
    render(lastSnapshot);
    alert(error.message);
  }
});

els.supplyWalletLink.addEventListener("click", () => setActiveView("wallet"));

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
    clearAuthErrorState();
    clearPendingOAuthProvider();
    await ensureSupabaseIdentity();
    await refreshAccountState();
    await ensureGatewayAccountLink();
    await refreshAccountState();
    renderAccountWallet();
    renderAccountApiKeys();
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
  authTrace("signOut start");
  els.authSignoutButton.disabled = true;
  clearPersistedSupabaseSession();
  resetAccountAuthState();
  postNativeSessionSync(null);
  render(lastSnapshot);
  const signOutTask = supabaseClient.auth
    .signOut({ scope: "local" })
    .then(({ error }) => {
      if (error) {
        authTrace(`signOut local failed ${error.message}`);
      } else {
        authTrace("signOut local success");
      }
    })
    .catch((error) => {
      authTrace(`signOut threw ${error.message}`);
    });
  try {
    await Promise.race([
      signOutTask,
      new Promise((resolve) => window.setTimeout(resolve, 1500)),
    ]);
  } finally {
    els.authSignoutButton.disabled = false;
  }
});

els.followXButton.addEventListener("click", () => {
  const url = "https://x.com/teale_ai";
  if (!postNativeMessage({ type: "openExternal", url })) {
    window.open(url, "_blank", "noopener,noreferrer");
  }
});

els.shareStoryButton.addEventListener("click", async () => {
  await copyText(SHARE_STORY_TEXT, "Share text");
});

els.localCurlCopy.addEventListener("click", async () => {
  await copyText(els.localCurl.textContent, "Local curl");
});

els.networkTokenCopy.addEventListener("click", async () => {
  await copyText(lastSnapshot?.demand?.network_bearer_token || "", "Device bearer");
});

els.networkToken.addEventListener("click", async () => {
  await copyValueWithFlash(
    els.networkToken,
    lastSnapshot?.demand?.network_bearer_token || "",
    "Device bearer",
    (value) => maskToken(value)
  );
});

els.networkCurlCopy.addEventListener("click", async () => {
  await copyText(els.networkCurl.textContent, "Network curl");
});

els.accountApiKeyCreate.addEventListener("click", async () => {
  await createAccountApiKey();
});

els.accountApiKeyCreatedCopy.addEventListener("click", async () => {
  await copyText(createdAccountApiKeyToken || "", "API key");
});

els.chatModelSelect.addEventListener("change", () => {
  const thread = selectedChatThread();
  const selectedKey = els.chatModelSelect.value;
  const option = currentChatModelOptions(lastSnapshot).find((item) => chatTargetKey(item) === selectedKey);
  if (!thread || !option || isChatBusy()) {
    renderChat(lastSnapshot);
    return;
  }
  thread.modelTarget = { provider: option.provider, modelId: option.modelId };
  chatRuntime.errorMessage = "";
  chatRuntime.infoMessage = "";
  persistChatState();
  renderChat(lastSnapshot);
});

els.chatInput.addEventListener("input", () => {
  renderChat(lastSnapshot);
});

els.chatInput.addEventListener("keydown", async (event) => {
  if (event.key === "Enter" && !event.shiftKey) {
    event.preventDefault();
    await sendChatMessage();
  }
});

els.chatSendButton.addEventListener("click", async () => {
  await sendChatMessage();
});

els.walletDeviceId.addEventListener("click", async () => {
  await copyValueWithFlash(
    els.walletDeviceId,
    lastSnapshot?.wallet?.current_device_id || "",
    "Device ID",
    (value) => truncateDeviceId(value)
  );
});

els.headerRefresh.addEventListener("click", async () => {
  if (walletRefreshInFlight) {
    return;
  }
  walletRefreshInFlight = true;
  render(lastSnapshot);
  try {
    lastSnapshot = await post(ROUTES.walletRefresh, {});
    await refreshAccountState();
    render(lastSnapshot);
  } catch (error) {
    alert(error.message);
  } finally {
    walletRefreshInFlight = false;
    render(lastSnapshot);
  }
});

els.ledgerExport.addEventListener("click", () => {
  exportLedgerCsv(deviceWalletBalance().transactions || []);
});

for (const input of [
  els.sendAsset,
  els.sendRecipient,
  els.sendAmount,
  els.sendMemo,
  els.accountSendAsset,
  els.accountSendRecipient,
  els.accountSendAmount,
  els.accountSendMemo,
]) {
  input.addEventListener("input", () => {
    walletSendStatus = "";
    accountSendStatus = "";
    updateSendControls();
  });
  input.addEventListener("change", () => {
    walletSendStatus = "";
    accountSendStatus = "";
    updateSendControls();
  });
}

els.sendSubmit.addEventListener("click", async () => {
  const amount = parseDisplayAmountToCredits(els.sendAmount.value || "");
  if (!Number.isInteger(amount)) {
    walletSendStatus = invalidAmountMessage();
    updateSendControls();
    return;
  }
  walletSendInFlight = true;
  walletSendStatus = "";
  updateSendControls();
  try {
    lastSnapshot = await post(ROUTES.walletSend, {
      asset: els.sendAsset.value,
      recipient: els.sendRecipient.value.trim(),
      amount,
      memo: els.sendMemo.value.trim() || null,
    });
    walletSendStatus = `Sent ${formatDisplayCredits(amount, true)}.`;
    els.sendAmount.value = "";
    els.sendMemo.value = "";
    await refreshAccountState();
    render(lastSnapshot);
  } catch (error) {
    walletSendStatus = error.message;
    updateSendControls();
  } finally {
    walletSendInFlight = false;
    updateSendControls();
  }
});

els.accountSendSubmit.addEventListener("click", async () => {
  const amount = parseDisplayAmountToCredits(els.accountSendAmount.value || "");
  if (!Number.isInteger(amount)) {
    accountSendStatus = invalidAmountMessage();
    updateSendControls();
    return;
  }
  accountSendInFlight = true;
  accountSendStatus = "";
  updateSendControls();
  try {
    accountSummary = await post(ROUTES.accountSend, {
      asset: els.accountSendAsset.value,
      recipient: els.accountSendRecipient.value.trim(),
      amount,
      memo: els.accountSendMemo.value.trim() || null,
    });
    accountSendStatus = `Sent ${formatDisplayCredits(amount, true)} from the account wallet.`;
    els.accountSendAmount.value = "";
    els.accountSendMemo.value = "";
    await refresh();
    render(lastSnapshot);
  } catch (error) {
    accountSendStatus = error.message;
    updateSendControls();
  } finally {
    accountSendInFlight = false;
    updateSendControls();
  }
});

for (const button of els.viewButtons) {
  button.addEventListener("click", () => setActiveView(button.dataset.viewButton));
}

els.languageSelect.addEventListener("change", (event) => {
  setLanguage(event.target.value);
  if (els.settingsMenu) {
    els.settingsMenu.open = false;
  }
});

els.displayUnitSelect.addEventListener("change", (event) => {
  setDisplayUnit(event.target.value);
});

els.privacyFilterSelect.addEventListener("change", async (event) => {
  const nextMode = event.target.value;
  try {
    await setPrivacyFilterMode(nextMode);
    if (els.settingsMenu) {
      els.settingsMenu.open = false;
    }
  } catch (error) {
    alert(`Could not update privacy filter mode: ${error.message}`);
    renderPrivacyFilter(lastSnapshot);
  }
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
document.addEventListener("click", (event) => {
  if (els.settingsMenu?.open && !els.settingsMenu.contains(event.target)) {
    els.settingsMenu.open = false;
  }
});
window.__tealeHandleOAuthCallback = async (url) => {
  pendingOAuthCallbackUrl = url;
  try {
    window.localStorage.setItem(OAUTH_CALLBACK_STORAGE_KEY, url);
  } catch (_error) {}
  await consumePendingOAuthCallback();
  await refreshAccountState();
  await ensureGatewayAccountLink();
  await refreshAccountState();
  renderAccountWallet();
  renderAccountApiKeys();
  renderAuthState();
  renderAccountDevices();
  renderHome(lastSnapshot);
};
window.__tealeSetLocalApiKey = (key) => {
  localApiKey = key || null;
};
window.__tealeHydrateNativeSession = async (session) => {
  pendingNativeSession = normalizeNativeSession(session);
  if (!pendingNativeSession || !supabaseClient) {
    return;
  }
  const hydrated = await applyPendingNativeSessionIfNeeded();
  if (!hydrated) {
    return;
  }
  authSession = hydrated;
  authUser = hydrated.user || null;
  await ensureSupabaseIdentity();
  await refreshAccountState();
  await ensureGatewayAccountLink();
  await refreshAccountState();
  renderAccountWallet();
  renderAccountApiKeys();
  renderAuthState();
  renderAccountDevices();
  renderHome(lastSnapshot);
};

applyTranslations();
setActiveView("home");
loadStoredOAuthCallback();
refresh().catch((error) => {
  consecutiveSnapshotFailures += 1;
  setDisconnected(error);
});
startPolling();
