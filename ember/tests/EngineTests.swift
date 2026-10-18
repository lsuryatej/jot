import Foundation

func runEngineTests() {
    suite("A ping lands on the other Mac") {
        let (a, b) = makePair()
        let t = at(2026, 11, 2, 21, 30)
        let sent = try! a.send(.spicy, at: t)
        equal(pings(published(sent)).count, 1, "sending publishes one ping")

        let got = deliver(sent, to: b, at: t.addingTimeInterval(2))
        let alert = alerts(got).first
        equal(alert?.title, "Surya", "titled with the sender's name, learned from hello")
        equal(alert?.body, "🌶️ Thinking about you", "default wording")
        equal(alert?.category, .pingDistance, "carries the long-distance reply buttons")
        equal(alert?.sound, "Pop", "each level has its own sound")
        equal(signals(got), 1, "and makes the icon glow")

        let acks = published(got).filter { if case .received = $0.payload { return true } else { return false } }
        equal(acks.count, 1, "the receiver acknowledges it")
        _ = deliver(got, to: a, at: t.addingTimeInterval(3))
        let mine = a.state.history.last(where: { $0.fromMe && $0.kind == .ping })
        check(mine?.reachedAt != nil, "the sender sees ✓✓ once it reached their Mac")
    }

    suite("Your own wording travels with the ping") {
        let (a, b) = makePair()
        var settings = a.state.settings
        settings.labels[Level.spicier.rawValue] = "  Boner alert 🍆  "
        _ = a.updateSettings(settings, at: at(2026, 11, 2))
        let got = deliver(try! a.send(.spicier, at: at(2026, 11, 2, 22)), to: b, at: at(2026, 11, 2, 22))
        equal(alerts(got).first?.body, "🌶️🌶️ Boner alert 🍆", "they read exactly what you wrote, trimmed")

        settings.labels[Level.spicier.rawValue] = String(repeating: "x", count: 500)
        _ = a.updateSettings(settings, at: at(2026, 11, 2, 23))
        let long = deliver(try! a.send(.spicier, at: at(2026, 11, 2, 23)), to: b, at: at(2026, 11, 2, 23))
        equal(alerts(long).first?.body.count, 80 + "🌶️🌶️ ".count, "but a runaway label is capped")
    }

    suite("Cooldown") {
        let (a, _) = makePair()
        let t = at(2026, 11, 2, 20)
        _ = try! a.send(.spicy, at: t)
        do {
            _ = try a.send(.fire, at: t.addingTimeInterval(20))
            check(false, "a second ping 20s later is refused")
        } catch let refusal as SendRefusal {
            equal(refusal, .coolingDown(seconds: 40), "a second ping 20s later is refused, with the wait")
        } catch {
            check(false, "unexpected error \(error)")
        }
        check((try? a.send(.fire, at: t.addingTimeInterval(61))) != nil, "a minute later it goes")
    }

    suite("Echoes and duplicates are dropped") {
        let (a, b) = makePair()
        let sent = try! a.send(.missYou, at: at(2026, 11, 3))
        equal(deliver(sent, to: a, at: at(2026, 11, 3)), [], "ntfy echoing your own ping back does nothing")
        check(!deliver(sent, to: b, at: at(2026, 11, 3)).isEmpty, "first delivery counts")
        equal(deliver(sent, to: b, at: at(2026, 11, 3)), [], "a redelivery after reconnect does nothing")
    }

    suite("Match: both ping within 15 minutes") {
        let (a, b) = makePair()
        let t = at(2026, 11, 4, 22)
        let fromA = try! a.send(.spicier, at: t)
        _ = deliver(fromA, to: b, at: t)
        let fromB = try! b.send(.fire, at: t.addingTimeInterval(5 * 60))
        equal(alerts(fromB).first?.title, "It's a match", "the second sender sees the match straight away")
        equal(alerts(fromB).first?.category, .call, "with a FaceTime button")

        let onA = deliver(fromB, to: a, at: t.addingTimeInterval(5 * 60 + 1))
        equal(alerts(onA).map(\.title), ["It's a match"], "the first sender gets the match instead of a plain ping")
        equal(a.state.history.filter { $0.kind == .match }.count, 1, "and it's in the history")
        equal(a.weekStats(at: t.addingTimeInterval(600)).matches, 1, "and in the weekly count")
        check(b.openPing(at: t.addingTimeInterval(400)) == nil, "a matched ping doesn't need a reply")
    }

    suite("Match: two 💛 is a softer match") {
        let (a, b) = makePair()
        let t = at(2026, 11, 4, 10)
        _ = deliver(try! a.send(.missYou, at: t), to: b, at: t)
        let fromB = try! b.send(.missYou, at: t.addingTimeInterval(60))
        equal(alerts(fromB).first?.body, "💛 You were thinking of each other at the same time.", "tender wording")
        equal(alerts(fromB).first?.category, nil, "no call button for a 💛")
    }

    suite("No match outside the window") {
        let (a, b) = makePair()
        let t = at(2026, 11, 5, 22)
        _ = deliver(try! a.send(.spicy, at: t), to: b, at: t)
        let fromB = try! b.send(.spicy, at: t.addingTimeInterval(20 * 60))
        equal(alerts(fromB).count, 0, "20 minutes apart is just two pings")
    }

    suite("A ping that arrives late is news, not a call to action") {
        let (a, b) = makePair()
        let sentAt = at(2026, 11, 6, 9)
        let mine = try! b.send(.spicy, at: sentAt.addingTimeInterval(-60))
        _ = mine
        let got = deliver(try! a.send(.fire, at: sentAt), to: b, at: sentAt.addingTimeInterval(45 * 60))
        let alert = alerts(got).first
        equal(alert?.sound, nil, "silent")
        check(alert?.title.contains("earlier") == true, "marked as earlier")
        check(alert?.body.contains("·") == true, "with the time it was sent")
        equal(signals(got), 0, "no glow")
        check(alert?.title != "It's a match", "and it can't make a match")
    }

    suite("Busy holds pings, then shows them together") {
        let (a, b) = makePair()
        let t = at(2026, 11, 7, 14)
        let busy = b.setBusy(until: t.addingTimeInterval(3600), at: t)
        _ = deliver(busy, to: a, at: t)
        equal(a.partnerBusyUntil(at: t), t.addingTimeInterval(3600), "the other Mac sees you're busy and until when")

        let got = deliver(try! a.send(.spicy, at: t.addingTimeInterval(60)), to: b, at: t.addingTimeInterval(60))
        equal(alerts(got).count, 0, "no notification while busy")
        equal(published(got).count, 1, "but it's still acknowledged")

        equal(alerts(b.tick(at: t.addingTimeInterval(1800))).count, 0, "nothing mid-way")
        let after = b.tick(at: t.addingTimeInterval(3601))
        equal(alerts(after).first?.title, "While you were busy", "a summary when it ends")
        check(alerts(after).first?.body.contains("🌶️") == true, "listing what came in")
        _ = deliver(after, to: a, at: t.addingTimeInterval(3601))
        equal(a.partnerBusyUntil(at: t.addingTimeInterval(3602)), nil, "and the other Mac learns you're free")
        equal(alerts(b.tick(at: t.addingTimeInterval(3700))).count, 0, "the summary shows once")
    }

    suite("Ending busy early releases held pings") {
        let (a, b) = makePair()
        let t = at(2026, 11, 7, 15)
        _ = b.setBusy(until: t.addingTimeInterval(3600), at: t)
        _ = deliver(try! a.send(.fire, at: t), to: b, at: t)
        equal(alerts(b.setBusy(until: nil, at: t.addingTimeInterval(60))).first?.title, "While you were busy", "clearing busy shows them")
    }

    suite("Quiet hours") {
        let night = QuietHours(start: 23 * 60, end: 7 * 60)
        check(night.contains(at(2026, 11, 1, 23, 30), calendar: ist), "23:30 is inside 23:00–07:00")
        check(night.contains(at(2026, 11, 1, 6, 59), calendar: ist), "06:59 is inside")
        check(!night.contains(at(2026, 11, 1, 7, 0), calendar: ist), "07:00 is not")
        check(!night.contains(at(2026, 11, 1, 12), calendar: ist), "noon is not")
        let day = QuietHours(start: 9 * 60, end: 17 * 60)
        check(day.contains(at(2026, 11, 1, 9), calendar: ist), "a non-wrapping range works too")
        check(!QuietHours(start: 60, end: 60).contains(at(2026, 11, 1, 1), calendar: ist), "an empty range is never quiet")
        equal(QuietHours.default.endDate(after: at(2026, 11, 1, 2), calendar: ist), at(2026, 11, 1, 8), "ends at 08:00")

        let (a, b) = makePair()
        var settings = b.state.settings
        settings.quietHoursOn = true
        let t = at(2026, 11, 8, 2)
        _ = deliver(b.updateSettings(settings, at: t), to: a, at: t)
        check(a.partnerIsQuiet(at: t), "the sender can see it's their quiet hours")
        let got = deliver(try! a.send(.fire, at: t), to: b, at: t)
        equal(alerts(got).first?.sound, nil, "the ping arrives without a sound")
        check(alerts(got).first != nil, "but it still arrives")
    }

    suite("Discreet notifications") {
        let (a, b) = makePair()
        var settings = b.state.settings
        settings.discreet = true
        _ = b.updateSettings(settings, at: at(2026, 11, 9))
        let alert = alerts(deliver(try! a.send(.spicier, at: at(2026, 11, 9)), to: b, at: at(2026, 11, 9))).first
        equal(alert?.title, "Ember", "no name")
        equal(alert?.body, "🌶️🌶️", "just the emoji")
    }

    suite("Replies") {
        let (a, b) = makePair()
        let t = at(2026, 11, 10, 21)
        let ping = try! a.send(.spicy, at: t)
        let pingID = pings(published(ping))[0].id
        _ = deliver(ping, to: b, at: t)
        equal(b.openPing(at: t.addingTimeInterval(30))?.id, pingID, "an unanswered ping shows reply buttons in the menu")

        let later = b.reply(.giveMe20, to: pingID, at: t.addingTimeInterval(60))
        equal(scheduled(later).first?.1, t.addingTimeInterval(60 + 20 * 60), "'give me 20' sets a timer on the replier's Mac")
        check(b.openPing(at: t.addingTimeInterval(61)) == nil, "and the ping is answered")

        let onA = deliver(later, to: a, at: t.addingTimeInterval(62))
        equal(alerts(onA).first?.body, "⏳ Give me 20", "the sender sees the reply")
        equal(scheduled(onA).first?.1, t.addingTimeInterval(60 + 20 * 60), "and gets the same timer")
        equal(scheduled(onA).first?.0.id, scheduled(later).first?.0.id, "one timer per ping, so it can't double up")

        let call = b.reply(.faceTime, to: pingID, at: t.addingTimeInterval(120))
        check(call.contains(.startFaceTime), "'FaceTime now' starts the call from the replier's Mac")
        let callOnA = alerts(deliver(call, to: a, at: t.addingTimeInterval(121))).first
        equal(callOnA?.body, "📞 FaceTiming you now", "the sender knows it's coming")
        equal(callOnA?.category, .call, "with a button to call back if it doesn't")

        let no = alerts(deliver(b.reply(.rainCheck, to: pingID, at: t.addingTimeInterval(180)), to: a, at: t.addingTimeInterval(180))).first
        equal(no?.sound, nil, "a rain check lands quietly")
        check(b.openPing(at: t.addingTimeInterval(2 * 3600)) == nil, "pings stop being answerable after an hour")
    }

    suite("Visit phases") {
        let plan = VisitPlan(start: at(2026, 11, 12, 0), end: at(2026, 11, 15, 0))
        equal(VisitPhase.of(plan, at: at(2026, 11, 10, 23), calendar: ist), .upcoming(days: 2), "two days out")
        equal(VisitPhase.of(plan, at: at(2026, 11, 11, 0, 5), calendar: ist), .upcoming(days: 1), "the day before")
        equal(VisitPhase.of(plan, at: at(2026, 11, 12, 8), calendar: ist), .together(day: 1, of: 4), "first day")
        equal(VisitPhase.of(plan, at: at(2026, 11, 15, 23, 59), calendar: ist), .together(day: 4, of: 4), "the last day counts")
        equal(VisitPhase.of(plan, at: at(2026, 11, 16, 9), calendar: ist), .comedown, "the day after is the comedown")
        equal(VisitPhase.of(plan, at: at(2026, 11, 17, 9), calendar: ist), .none, "then back to normal")
        equal(VisitPhase.of(nil, at: at(2026, 11, 17), calendar: ist), .none, "no visit, no phase")
    }

    suite("Visit syncs both ways, last change wins") {
        let (a, b) = makePair()
        let plan = VisitPlan(start: at(2026, 12, 20, 0), end: at(2026, 12, 24, 0))
        let set = a.setVisit(plan, at: at(2026, 11, 1, 10))
        let onB = deliver(set, to: b, at: at(2026, 11, 1, 10))
        equal(b.state.visit.plan, plan, "the other Mac gets the dates")
        check(alerts(onB).first?.body.hasPrefix("✈️ Visit set") == true, "and a heads-up")

        let cleared = b.setVisit(nil, at: at(2026, 11, 2, 10))
        _ = deliver(cleared, to: a, at: at(2026, 11, 2, 10))
        equal(a.state.visit.plan, nil, "clearing syncs too")

        // A Mac that was off comes back with the old plan in its hello.
        let (c, d) = makePair()
        _ = deliver(c.setVisit(plan, at: at(2026, 11, 1)), to: d, at: at(2026, 11, 1))
        let newer = VisitPlan(start: at(2026, 12, 21, 0), end: at(2026, 12, 23, 0))
        _ = d.setVisit(newer, at: at(2026, 11, 3)) // c was offline for this
        let answer = deliver(c.hello(at: at(2026, 11, 4)), to: d, at: at(2026, 11, 4))
        equal(d.state.visit.plan, newer, "a stale copy doesn't win")
        _ = deliver(answer, to: c, at: at(2026, 11, 4))
        equal(c.state.visit.plan, newer, "and the stale Mac is brought up to date")
    }

    suite("Hello is answered once, not forever") {
        let (a, b) = makePair()
        let reply = deliver(a.hello(at: at(2026, 11, 5)), to: b, at: at(2026, 11, 5))
        equal(published(reply).count, 1, "the other Mac answers a hello")
        equal(published(deliver(reply, to: a, at: at(2026, 11, 5))).count, 0, "and the answer isn't answered")
    }

    suite("Together mode") {
        let (a, b) = makePair()
        let plan = VisitPlan(start: at(2026, 12, 20, 0), end: at(2026, 12, 24, 0))
        _ = deliver(a.setVisit(plan, at: at(2026, 11, 1)), to: b, at: at(2026, 11, 1))
        let t = at(2026, 12, 21, 20)
        let got = deliver(try! a.send(.fire, at: t), to: b, at: t)
        let alert = alerts(got).first
        equal(alert?.category, .pingTogether, "together replies instead of FaceTime")
        equal(alert?.sound, nil, "no sound across a room")
        equal(alert?.body, "🔥 Come find me.", "and the wording fits the room")
        equal(signals(got), 1, "the glowing icon is the signal")
        equal(Reply.options(together: true), [.onMyWay, .afterThis, .notNow], "replies for when you're in the same place")
    }

    suite("Visit milestones show once, and not at night") {
        let (a, _) = makePair()
        var settings = a.state.settings
        settings.quietHoursOn = true
        _ = a.updateSettings(settings, at: at(2026, 11, 1))
        _ = a.setVisit(VisitPlan(start: at(2026, 12, 20, 0), end: at(2026, 12, 22, 0)), at: at(2026, 11, 1))

        equal(alerts(a.tick(at: at(2026, 12, 19, 2))).count, 0, "the eve notice waits out quiet hours")
        equal(alerts(a.tick(at: at(2026, 12, 19, 9))).first?.title, "✈️ Tomorrow", "then shows in the morning")
        equal(alerts(a.tick(at: at(2026, 12, 19, 10))).count, 0, "once")
        equal(alerts(a.tick(at: at(2026, 12, 20, 10))).first?.title, "🫶 Together mode", "together mode announces itself")
        equal(alerts(a.tick(at: at(2026, 12, 23, 10))).first?.title, "💛 Back to long distance", "and the comedown the day after")
        equal(alerts(a.tick(at: at(2026, 12, 23, 18))).count, 0, "once")
    }

    suite("Saved state survives new and missing fields") {
        let settings = try? JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
        equal(settings, Settings(), "empty settings decode to defaults")
        let partial = try? JSONDecoder().decode(Settings.self, from: Data(#"{"myName":"Surya","hotKey":"someFutureKey"}"#.utf8))
        equal(partial?.myName, "Surya", "known fields are kept")
        equal(partial?.hotKey, .controlOptionE, "an unknown value falls back instead of failing")
        let state = try? JSONDecoder().decode(EngineState.self, from: Data(#"{"away":true}"#.utf8))
        equal(state?.away, true, "engine state decodes from a partial file")

        var full = EngineState()
        full.settings.myName = "Surya"
        full.busyUntil = Date(timeIntervalSince1970: 1_800_000_000)
        full.history = [HistoryEntry(id: UUID(), at: Date(timeIntervalSince1970: 1_800_000_000), fromMe: true, kind: .ping, text: "🌶️ hi")]
        let data = try! JSONEncoder().encode(full)
        equal(try? JSONDecoder().decode(EngineState.self, from: data), full, "a full round trip is lossless")
    }
}
