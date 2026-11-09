import SwiftUI
import WebKit

/// Connexion par le site de Deezer (comme sur la version bureau) : l'utilisateur se connecte normalement,
/// l'app récupère le cookie `arl` puis ferme la page.
/// La page tourne dans un espace privé en mémoire (`nonPersistent`) : ni cookie, ni cache, ni fichier
/// ne reste sur le téléphone une fois la feuille fermée.
struct WebLoginSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onArl: (String) -> Void
    @State private var loading = true

    var body: some View {
        NavigationStack {
            WebLoginView(loading: $loading) { arl in
                dismiss()
                onArl(arl)
            }
            .ignoresSafeArea(edges: .bottom)
            .overlay {
                if loading { ProgressView().controlSize(.large) }
            }
            .navigationTitle(tr("Connexion à Deezer"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button(tr("Annuler")) { dismiss() } }
            }
        }
    }
}

private struct WebLoginView: UIViewRepresentable {
    @Binding var loading: Bool
    let onArl: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent() // tout en mémoire, effacé avec la page
        let web = WKWebView(frame: .zero, configuration: config)
        // Site « ordinateur » : la version mobile pousse vers l'app Deezer au lieu d'afficher la connexion.
        web.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        config.websiteDataStore.httpCookieStore.add(context.coordinator)
        context.coordinator.store = config.websiteDataStore.httpCookieStore
        if let url = URL(string: "https://www.deezer.com/login") { web.load(URLRequest(url: url)) }
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) {
        web.stopLoading()
        web.navigationDelegate = nil
        web.uiDelegate = nil
        coordinator.store?.remove(coordinator)
    }

    final class Coordinator: NSObject, WKHTTPCookieStoreObserver, WKNavigationDelegate, WKUIDelegate {
        /// Lien ou bouton qui ouvre une nouvelle fenêtre (connexion par un réseau social) : chargé dans la page elle-même,
        /// au lieu d'être ignoré sans rien faire.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
            return nil
        }

        private let parent: WebLoginView
        weak var store: WKHTTPCookieStore?
        private var done = false

        init(_ parent: WebLoginView) { self.parent = parent }

        /// Le cookie `arl` n'apparaît qu'une fois connecté : on le prend une seule fois.
        func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
            guard !done else { return }
            cookieStore.getAllCookies { [weak self] cookies in
                guard let self, !self.done,
                      let arl = cookies.first(where: { $0.name == "arl" && $0.domain.hasSuffix("deezer.com") && !$0.value.isEmpty })?.value
                else { return }
                self.done = true
                self.parent.onArl(arl)
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { parent.loading = true }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { parent.loading = false }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { parent.loading = false }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { parent.loading = false }
    }
}
