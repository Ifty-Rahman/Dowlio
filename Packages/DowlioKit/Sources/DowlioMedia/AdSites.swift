import Foundation

enum AdSites {
    static let all: Set<String> = [
        "doubleclick.net", "googlesyndication.com", "googleadservices.com", "googletagmanager.com", "google-analytics.com",
        "adnxs.com", "amazon-adsystem.com", "taboola.com", "outbrain.com", "criteo.com", "criteo.net", "pubmatic.com",
        "rubiconproject.com", "adsrvr.org", "openx.net", "casalemedia.com", "moatads.com", "scorecardresearch.com", "hotjar.com",
        "exoclick.com", "exosrv.com", "juicyads.com", "trafficjunky.net", "magsrv.com", "tsyndicate.com", "adsterra.com", "popads.net",
        "propellerads.com", "spotxchange.com", "springserve.com", "teads.tv", "adform.net", "smartadserver.com",
    ]

    static func hosts(_ url: URL) -> Bool {
        all.contains(PageAnalyzer.site(of: url))
    }
}
