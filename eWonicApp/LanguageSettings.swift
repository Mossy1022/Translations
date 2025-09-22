import Foundation
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
  case english = "en-US"
  case spanish = "es-US"
  case french  = "fr-FR"
  case german  = "de-DE"
  case chinese = "zh-CN"

  var id: String { rawValue }

  var localeIdentifier: String {
    switch self {
    case .english: return "en"
    case .spanish: return "es"
    case .french:  return "fr"
    case .german:  return "de"
    case .chinese: return "zh-Hans"
    }
  }

  var nativeName: String {
    switch self {
    case .english: return "English"
    case .spanish: return "Español"
    case .french:  return "Français"
    case .german:  return "Deutsch"
    case .chinese: return "中文（简体）"
    }
  }

  var welcomeMessage: String {
    switch self {
    case .english: return "Welcome! Select your language to get started."
    case .spanish: return "¡Bienvenido! Selecciona tu idioma para comenzar."
    case .french:  return "Bienvenue ! Sélectionnez votre langue pour commencer."
    case .german:  return "Willkommen! Wähle deine Sprache, um loszulegen."
    case .chinese: return "欢迎！请选择您的语言以开始。"
    }
  }
}

enum LanguageSettings {
  enum Keys {
    static let selectedLanguage    = "app.preferredLanguage"
    static let didCompleteWelcome  = "app.didCompleteWelcome"
  }

  static var currentLanguage: AppLanguage {
    if let stored = UserDefaults.standard.string(forKey: Keys.selectedLanguage),
       let lang = AppLanguage(rawValue: stored) {
      return lang
    }
    return .english
  }

  static var hasPreferredLanguage: Bool {
    UserDefaults.standard.string(forKey: Keys.selectedLanguage) != nil
  }

  static func updateLanguage(_ language: AppLanguage) {
    UserDefaults.standard.set(language.rawValue, forKey: Keys.selectedLanguage)
  }
}

enum Localization {
  private static let translations: [AppLanguage: [String: String]] = [
    .spanish: [
      "Select your language": "Selecciona tu idioma",
      "Continue": "Continuar",
      "We'll use this for translations and the app interface.": "Usaremos esto para las traducciones y la interfaz de la aplicación.",
      "Break language barriers instantly.": "Rompe las barreras del idioma al instante.",
      "Hands-free, real-time speech": "Habla manos libres en tiempo real",
      "Auto-discovers nearby users": "Detecta automáticamente a usuarios cercanos",
      "No special hardware required": "No se necesita hardware especial",
      "Start": "Iniciar",
      "Peer": "Par",
      "One Phone": "Un teléfono",
      "Convention": "Convención",
      "I Speak": "Yo hablo",
      "Peer Hears": "Mi par escucha",
      "Speaker": "Orador",
      "I Hear": "Yo escucho",
      "Voices": "Voces",
      "System defaults": "Valores predeterminados del sistema",
      "You": "Tú",
      "Live": "En vivo",
      "Mic Sensitivity": "Sensibilidad del micrófono",
      "Playback Speed": "Velocidad de reproducción",
      "System default": "Predeterminado del sistema",
      "Processing…": "Procesando…",
      "Stop": "Detener",
      "Connect to a Peer": "Conéctate con un par",
      "Host": "Anfitrión",
      "Join": "Unirse",
      "Found Peers:": "Pares encontrados:",
      "Searching…": "Buscando…",
      "Waiting…": "Esperando…",
      "Stop Activities": "Detener actividades",
      "Clear History": "Borrar historial",
      "Conversation": "Conversación",
      "Enter text": "Introducir texto",
      "No connected peers – message not sent": "No hay pares conectados: mensaje no enviado",
      "Failed to encode/compress MessageData": "Error al codificar/comprimir MessageData",
      "session.send error: %@": "Error de session.send: %@",
      "Peer %@ disconnected": "El par %@ se desconectó",
      "Failed to decode message from %@": "Error al decodificar el mensaje de %@",
      "Advertiser error: %@": "Error del anunciante: %@",
      "Browser error: %@": "Error del explorador: %@",
      "Tap 'Start' to speak.": "Toca \"Iniciar\" para hablar.",
      "Not Connected": "Sin conexión",
      "Checking permissions…": "Verificando permisos…",
      "Permissions granted.": "Permisos concedidos.",
      "Speech & Microphone permission denied.": "Permiso de voz y micrófono denegado.",
      "Missing permissions.": "Faltan permisos.",
      "Not connected.": "Sin conexión.",
      "Listening…": "Escuchando…",
      "(inaudible)": "(inaudible)",
      "(unavailable)": "(no disponible)",
      "peer": "par",
      "Connecting…": "Conectando…",
      "Connected to %@": "Conectado a %@",
      "Unknown": "Desconocido",
      "…": "…",
      "Text translation failed. Speaking original.": "Falló la traducción del texto. Reproduciendo el original.",
      "(untranslated) %@": "(sin traducir) %@",
      "Peer: %@": "Par: %@",
      "Text translation failed.": "La traducción del texto falló.",
      "Grant Permissions": "Conceder permisos"
    ],
    .french: [
      "Select your language": "Sélectionnez votre langue",
      "Continue": "Continuer",
      "We'll use this for translations and the app interface.": "Nous l’utiliserons pour les traductions et l’interface de l’application.",
      "Break language barriers instantly.": "Brisez instantanément les barrières linguistiques.",
      "Hands-free, real-time speech": "Parole mains libres en temps réel",
      "Auto-discovers nearby users": "Détecte automatiquement les utilisateurs à proximité",
      "No special hardware required": "Aucun matériel spécial requis",
      "Start": "Démarrer",
      "Peer": "Pair",
      "One Phone": "Un téléphone",
      "Convention": "Convention",
      "I Speak": "Je parle",
      "Peer Hears": "Mon pair entend",
      "Speaker": "Orateur",
      "I Hear": "J'entends",
      "Voices": "Voix",
      "System defaults": "Valeurs par défaut du système",
      "You": "Vous",
      "Live": "En direct",
      "Mic Sensitivity": "Sensibilité du micro",
      "Playback Speed": "Vitesse de lecture",
      "System default": "Valeur par défaut du système",
      "Processing…": "Traitement…",
      "Stop": "Arrêter",
      "Connect to a Peer": "Se connecter à un pair",
      "Host": "Héberger",
      "Join": "Rejoindre",
      "Found Peers:": "Pairs trouvés :",
      "Searching…": "Recherche…",
      "Waiting…": "En attente…",
      "Stop Activities": "Arrêter les activités",
      "Clear History": "Effacer l’historique",
      "Conversation": "Conversation",
      "Enter text": "Saisir du texte",
      "No connected peers – message not sent": "Aucun pair connecté : message non envoyé",
      "Failed to encode/compress MessageData": "Échec de l’encodage/de la compression de MessageData",
      "session.send error: %@": "Erreur session.send : %@",
      "Peer %@ disconnected": "Le pair %@ s’est déconnecté",
      "Failed to decode message from %@": "Échec du décodage du message de %@",
      "Advertiser error: %@": "Erreur de l’annonceur : %@",
      "Browser error: %@": "Erreur du navigateur : %@",
      "Tap 'Start' to speak.": "Touchez « Démarrer » pour parler.",
      "Not Connected": "Non connecté",
      "Checking permissions…": "Vérification des autorisations…",
      "Permissions granted.": "Autorisations accordées.",
      "Speech & Microphone permission denied.": "Autorisation de voix et de micro refusée.",
      "Missing permissions.": "Autorisations manquantes.",
      "Not connected.": "Non connecté.",
      "Listening…": "Écoute…",
      "(inaudible)": "(inaudible)",
      "(unavailable)": "(indisponible)",
      "peer": "pair",
      "Connecting…": "Connexion…",
      "Connected to %@": "Connecté à %@",
      "Unknown": "Inconnu",
      "…": "…",
      "Text translation failed. Speaking original.": "Échec de la traduction du texte. Lecture de l’original.",
      "(untranslated) %@": "(non traduit) %@",
      "Peer: %@": "Pair : %@",
      "Text translation failed.": "Échec de la traduction du texte.",
      "Grant Permissions": "Accorder les autorisations"
    ],
    .german: [
      "Select your language": "Wähle deine Sprache",
      "Continue": "Weiter",
      "We'll use this for translations and the app interface.": "Wir verwenden diese Auswahl für Übersetzungen und die App-Oberfläche.",
      "Break language barriers instantly.": "Überwinde Sprachbarrieren sofort.",
      "Hands-free, real-time speech": "Freihändige Sprache in Echtzeit",
      "Auto-discovers nearby users": "Findet automatisch Nutzer in der Nähe",
      "No special hardware required": "Keine spezielle Hardware erforderlich",
      "Start": "Start",
      "Peer": "Partner",
      "One Phone": "Ein Telefon",
      "Convention": "Konferenz",
      "I Speak": "Ich spreche",
      "Peer Hears": "Mein Partner hört",
      "Speaker": "Redner",
      "I Hear": "Ich höre",
      "Voices": "Stimmen",
      "System defaults": "Systemstandards",
      "You": "Du",
      "Live": "Live",
      "Mic Sensitivity": "Mikrofonempfindlichkeit",
      "Playback Speed": "Wiedergabegeschwindigkeit",
      "System default": "Systemstandard",
      "Processing…": "Verarbeitung…",
      "Stop": "Stopp",
      "Connect to a Peer": "Mit einem Partner verbinden",
      "Host": "Host",
      "Join": "Beitreten",
      "Found Peers:": "Gefundene Partner:",
      "Searching…": "Suche…",
      "Waiting…": "Warten…",
      "Stop Activities": "Aktivitäten stoppen",
      "Clear History": "Verlauf löschen",
      "Conversation": "Unterhaltung",
      "Enter text": "Text eingeben",
      "No connected peers – message not sent": "Keine verbundenen Partner – Nachricht nicht gesendet",
      "Failed to encode/compress MessageData": "Kodierung/Komprimierung von MessageData fehlgeschlagen",
      "session.send error: %@": "session.send-Fehler: %@",
      "Peer %@ disconnected": "Partner %@ wurde getrennt",
      "Failed to decode message from %@": "Nachricht von %@ konnte nicht dekodiert werden",
      "Advertiser error: %@": "Advertiser-Fehler: %@",
      "Browser error: %@": "Browser-Fehler: %@",
      "Tap 'Start' to speak.": "Tippe auf \"Start\", um zu sprechen.",
      "Not Connected": "Nicht verbunden",
      "Checking permissions…": "Berechtigungen werden überprüft…",
      "Permissions granted.": "Berechtigungen gewährt.",
      "Speech & Microphone permission denied.": "Sprach- und Mikrofonberechtigung verweigert.",
      "Missing permissions.": "Fehlende Berechtigungen.",
      "Not connected.": "Nicht verbunden.",
      "Listening…": "Hören…",
      "(inaudible)": "(unhörbar)",
      "(unavailable)": "(nicht verfügbar)",
      "peer": "partner",
      "Connecting…": "Verbindung wird hergestellt…",
      "Connected to %@": "Verbunden mit %@",
      "Unknown": "Unbekannt",
      "…": "…",
      "Text translation failed. Speaking original.": "Textübersetzung fehlgeschlagen. Original wird wiedergegeben.",
      "(untranslated) %@": "(nicht übersetzt) %@",
      "Peer: %@": "Partner: %@",
      "Text translation failed.": "Textübersetzung fehlgeschlagen.",
      "Grant Permissions": "Berechtigungen erteilen"
    ],
    .chinese: [
      "Select your language": "选择你的语言",
      "Continue": "继续",
      "We'll use this for translations and the app interface.": "我们将使用此语言用于翻译和应用界面。",
      "Break language barriers instantly.": "即时打破语言障碍。",
      "Hands-free, real-time speech": "免提实时语音",
      "Auto-discovers nearby users": "自动发现附近用户",
      "No special hardware required": "无需特殊硬件",
      "Start": "开始",
      "Peer": "同伴",
      "One Phone": "单机对话",
      "Convention": "会议模式",
      "I Speak": "我说",
      "Peer Hears": "同伴听",
      "Speaker": "主讲人",
      "I Hear": "我听",
      "Voices": "语音",
      "System defaults": "系统默认值",
      "You": "你",
      "Live": "实时",
      "Mic Sensitivity": "麦克风灵敏度",
      "Playback Speed": "播放速度",
      "System default": "系统默认",
      "Processing…": "处理中…",
      "Stop": "停止",
      "Connect to a Peer": "连接到同伴",
      "Host": "主持",
      "Join": "加入",
      "Found Peers:": "找到的同伴：",
      "Searching…": "搜索中…",
      "Waiting…": "等待中…",
      "Stop Activities": "停止活动",
      "Clear History": "清除历史",
      "Conversation": "对话",
      "Enter text": "输入文本",
      "No connected peers – message not sent": "无连接的同伴——消息未发送",
      "Failed to encode/compress MessageData": "编码或压缩 MessageData 失败",
      "session.send error: %@": "session.send 错误：%@",
      "Peer %@ disconnected": "同伴 %@ 已断开连接",
      "Failed to decode message from %@": "无法解码来自 %@ 的消息",
      "Advertiser error: %@": "广播出错：%@",
      "Browser error: %@": "浏览器错误：%@",
      "Tap 'Start' to speak.": "点击“开始”进行讲话。",
      "Not Connected": "未连接",
      "Checking permissions…": "正在检查权限…",
      "Permissions granted.": "权限已授予。",
      "Speech & Microphone permission denied.": "语音和麦克风权限被拒绝。",
      "Missing permissions.": "缺少权限。",
      "Not connected.": "未连接。",
      "Listening…": "正在聆听…",
      "(inaudible)": "（无法听清）",
      "(unavailable)": "（不可用）",
      "peer": "同伴",
      "Connecting…": "正在连接…",
      "Connected to %@": "已连接到%@",
      "Unknown": "未知",
      "…": "…",
      "Text translation failed. Speaking original.": "文本翻译失败。正在播放原文。",
      "(untranslated) %@": "（未翻译）%@",
      "Peer: %@": "同伴：%@",
      "Text translation failed.": "文本翻译失败。",
      "Grant Permissions": "授予权限"
    ]
  ]

  static func localized(_ key: String) -> String {
    localized(key, arguments: [])
  }

  static func localized(_ key: String, _ args: CVarArg...) -> String {
    localized(key, arguments: args)
  }

fileprivate static func localized(_ key: String, arguments: [CVarArg]) -> String {
    let language = LanguageSettings.currentLanguage
    let template = translations[language]?[key] ?? key
    guard !arguments.isEmpty else { return template }
    return String(format: template,
                  locale: Locale(identifier: language.localeIdentifier),
                  arguments: arguments)
  }
}

extension String {
  var localized: String { Localization.localized(self) }

  func localizedFormat(_ args: CVarArg...) -> String {
    Localization.localized(self, arguments: args)
  }
}
