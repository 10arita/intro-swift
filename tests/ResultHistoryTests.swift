import Foundation

@main private struct ResultHistoryTests {
    static func main() throws {
        let legacy = Data("""
        {"id":"11111111-1111-1111-1111-111111111111","date":0,"playlist":"Old playlist","total":2,"correct":1,"averagePush":1.5,"score":49.375,"rank":"D"}
        """.utf8)
        let restored = try JSONDecoder().decode(SoloResult.self, from: legacy)
        precondition(restored.rounds == nil && restored.correct == 1 && restored.rank == "D",
                     "Existing saved results must load when round details are absent")

        let first = Song(id: "demo:first", title: "青空", artist: "Artist",
                         previewURL: URL(fileURLWithPath: "/device-only/audio.wav"), durationMS: 180_000, genre: "Pop")
        let second = Song(id: "itunes:2", title: "春風", artist: "Artist",
                          previewURL: URL(string: "https://example.com/audio.m4a"), durationMS: 180_000, genre: "Pop")
        let rounds = [SoloRoundResult(song: first.portableReviewSong, correct: true, pushTime: 1.5),
                      SoloRoundResult(song: second, correct: false, pushTime: nil)]
        let result = SoloResult.make(playlist: "Night music", total: 2, pushTimes: [1.5], rounds: rounds)
        let profile = CloudProfile(history: [result])
        let reloaded = try JSONDecoder().decode(CloudProfile.self, from: profile.encoded())
        let saved = reloaded.history[0]
        precondition(saved.id == result.id && saved.score == result.score && saved.correct == 1)
        precondition(saved.rounds?.count == 2)
        precondition(saved.rounds?[0].song.title == "青空" && saved.rounds?[0].correct == true)
        precondition(saved.rounds?[0].pushTime == 1.5 && saved.rounds?[0].song.previewURL == nil,
                     "A synced result must retain its accepted PUSH time without a device-local demo URL")
        precondition(saved.rounds?[1].correct == false && saved.rounds?[1].pushTime == nil)
        precondition(saved.rounds?[1].song.previewURL == second.previewURL)
        precondition(reloaded.merging(profile).history.count == 1,
                     "Syncing the same session must not duplicate its result or question details")
        print("Result history tests passed (legacy decoding, song outcomes, PUSH times, cloud sync)")
    }
}
