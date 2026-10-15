import EventKit
import Foundation
import Testing
import UNICore
@testable import UNISync

@Suite("Sala nova por compromisso")
struct MeetingRoomFactoryTests {
    @Test("Meet cria a sala pelo Calendar e devolve o hangoutLink")
    func meetMintsViaCalendar() async throws {
        let session = StubURLProtocol.session(routes: [
            "/calendar/v3/calendars/primary/events": [.json(
                #"{"hangoutLink":"https://meet.google.com/aaa-bbbb-ccc"}"#
            )],
        ])
        let client = GoogleMeetClient(
            session: session,
            accessToken: { "token" },
            baseURL: URL(string: "https://calendar.example/calendar/v3/")!
        )
        let start = Date(timeIntervalSince1970: 1_788_163_200)
        let minted = try await client.createConference(
            MeetingRoomRequest(
                service: .meet,
                account: Account(
                    id: "g", address: "a@gmail.com", displayName: "A",
                    provider: .gmail, host: "gmail",
                    tintLightHex: "#000", tintDarkHex: "#fff"
                ),
                title: "Revisão",
                start: start,
                end: start.addingTimeInterval(1800)
            )
        )
        #expect(minted.link == "https://meet.google.com/aaa-bbbb-ccc")
        let pedidos = StubURLProtocol.requests(for: session)
        #expect(pedidos.contains { $0.path.hasSuffix("/calendars/primary/events") })
        #expect(pedidos.contains { $0.query.contains("conferenceDataVersion=1") })
    }

    @Test("Meet recusa resposta sem URI")
    func meetRejectsMissingURI() async {
        let session = StubURLProtocol.session(routes: [
            "/calendar/v3/calendars/primary/events": [.json(#"{}"#)],
        ])
        let client = GoogleMeetClient(
            session: session,
            accessToken: { "token" },
            baseURL: URL(string: "https://calendar.example/calendar/v3/")!
        )
        let start = Date(timeIntervalSince1970: 1_788_163_200)
        await #expect(throws: MeetingRoomError.self) {
            _ = try await client.createConference(
                MeetingRoomRequest(
                    service: .meet,
                    account: Account(
                        id: "g", address: "a@gmail.com", displayName: "A",
                        provider: .gmail, host: "gmail",
                        tintLightHex: "#000", tintDarkHex: "#fff"
                    ),
                    title: "Revisão",
                    start: start,
                    end: start.addingTimeInterval(1800)
                )
            )
        }
    }

    @Test("EventKit traduz diário, úteis e semanal")
    func eventKitRules() throws {
        let daily = RecurrenceRule(frequency: .daily, interval: 2)
        let ekDaily = try #require(EventKitRecurrence.make(daily))
        #expect(ekDaily.frequency == .daily)
        #expect(ekDaily.interval == 2)

        let weekdays = RecurrenceRule(frequency: .weekdays)
        let ekDays = try #require(EventKitRecurrence.make(weekdays))
        #expect(ekDays.frequency == .weekly)
        #expect((ekDays.daysOfTheWeek ?? []).map(\.dayOfTheWeek) == [
            .monday, .tuesday, .wednesday, .thursday, .friday
        ])

        #expect(EventKitRecurrence.make(.none) == nil)
    }
}
