import Foundation
import SpotifyiOS

/// Controls only the Spotify app installed on this iPhone. No Connect device is selected.
@MainActor final class SpotifyRemote: NSObject, @preconcurrency SPTAppRemoteDelegate {
    private var appRemote: SPTAppRemote?
    private var clientID = ""
    private var waiters: [CheckedContinuation<Void, Error>] = []
    private var timeout: Task<Void, Never>?
    private var authorizing = false

    private var remote: SPTAppRemote {
        if let appRemote { return appRemote }
        let configuration = SPTConfiguration(clientID: clientID,
                                             redirectURL: URL(string: "intol://spotify-remote")!)
        let value = SPTAppRemote(configuration: configuration, logLevel: .error)
        value.delegate = self
        appRemote = value
        return value
    }

    func prepare(clientID: String, accessToken: String) async throws {
        guard !clientID.isEmpty else { throw AppError.message("Spotify Client ID を設定してください") }
        if self.clientID != clientID {
            disconnect()
            self.clientID = clientID
        }
        if remote.isConnected { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            waiters.append(continuation)
            guard waiters.count == 1 else { return }
            remote.connectionParameters.accessToken = accessToken
            timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(30)) }
                catch { return }
                self?.finish(AppError.message("Spotify アプリとの接続が時間切れになりました。アプリを開いてから再試行してください"))
            }
            remote.connect()
        }
    }

    func handleCallback(_ url: URL) -> Bool {
        guard url.scheme == "intol", url.host == "spotify-remote" else { return false }
        guard let parameters = remote.authorizationParameters(from: url) else {
            finish(AppError.message("Spotify アプリからの認証結果を読み取れません"))
            return true
        }
        if let token = parameters[SPTAppRemoteAccessTokenKey] {
            remote.connectionParameters.accessToken = token
            remote.connect()
        } else {
            finish(AppError.message(parameters[SPTAppRemoteErrorDescriptionKey] ?? "Spotify アプリへの接続が許可されませんでした"))
        }
        return true
    }

    func disconnect() {
        appRemote?.disconnect()
        appRemote = nil
        finish(AppError.message("Spotify アプリとの接続を解除しました"))
    }

    func play(uri: String, offsetMS: Int) async throws {
        guard let player = remote.playerAPI, remote.isConnected else {
            throw AppError.message("この iPhone の Spotify アプリに接続できません")
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            player.play(uri) { _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
        try Task.checkCancellation()
        if offsetMS > 0 {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                player.seek(toPosition: max(0, offsetMS)) { _, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
        }
        // The play callback acknowledges the command. Wait until Spotify reports
        // that this track is actually playing before starting a solo round timer.
        for _ in 0..<40 {
            try Task.checkCancellation()
            let state: (any SPTAppRemotePlayerState)? = try? await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<(any SPTAppRemotePlayerState), Error>) in
                player.getPlayerState { result, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let state = result as? any SPTAppRemotePlayerState { continuation.resume(returning: state) }
                    else { continuation.resume(throwing: AppError.message("Spotify の再生状態を確認できません")) }
                }
            }
            if let state, state.track.uri == uri, !state.isPaused { return }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw AppError.message("Spotify の再生開始を確認できません。接続を確認して再試行してください")
    }

    func pause() async throws {
        guard let player = appRemote?.playerAPI, appRemote?.isConnected == true else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            player.pause { _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    func appRemoteDidEstablishConnection(_ appRemote: SPTAppRemote) {
        if authorizing {
            // authorizeAndPlayURI wakes Spotify by resuming music. Silence it before the game.
            appRemote.playerAPI?.pause { [weak self] _, error in
                self?.finish(error)
            }
        } else {
            finish(nil)
        }
    }

    func appRemote(_ appRemote: SPTAppRemote, didFailConnectionAttemptWithError error: Error?) {
        guard !waiters.isEmpty else { return }
        guard !authorizing else {
            finish(error ?? AppError.message("Spotify アプリに接続できません"))
            return
        }
        authorizing = true
        appRemote.authorizeAndPlayURI("") { [weak self] installed in
            if !installed {
                Task { @MainActor [weak self] in
                    self?.finish(AppError.message("この iPhone に Spotify アプリをインストールしてください"))
                }
            }
        }
    }

    func appRemote(_ appRemote: SPTAppRemote, didDisconnectWithError error: Error?) {
        if !waiters.isEmpty && !authorizing {
            finish(error ?? AppError.message("Spotify アプリとの接続が切れました"))
        }
    }

    private func finish(_ error: Error?) {
        timeout?.cancel()
        timeout = nil
        authorizing = false
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            if let error { waiter.resume(throwing: error) }
            else { waiter.resume() }
        }
    }
}
