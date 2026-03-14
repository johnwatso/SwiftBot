import Foundation

// MARK: - EventBus System

/// A marker protocol for events that can be published and subscribed through `EventBus`.
protocol Event {}

/// A token representing a subscription to an event.
/// Use this token to unsubscribe from the event.
struct SubscriptionToken: Hashable, Identifiable {
    let id: UUID
    init() {
        self.id = UUID()
    }
}

/// A thread-safe event bus supporting typed publish/subscribe with async handlers.
final class EventBus {
    private actor Storage {
        private var subscribers: [ObjectIdentifier: [SubscriptionToken: (Any) async -> Void]] = [:]

        func add(type: ObjectIdentifier, token: SubscriptionToken, handler: @escaping (Any) async -> Void) {
            if subscribers[type] != nil {
                subscribers[type]![token] = handler
            } else {
                subscribers[type] = [token: handler]
            }
        }

        func remove(token: SubscriptionToken) {
            for (key, var dict) in subscribers {
                dict[token] = nil
                if dict.isEmpty {
                    subscribers[key] = nil
                } else {
                    subscribers[key] = dict
                }
            }
        }

        func snapshotHandlers(for type: ObjectIdentifier) -> [(Any) async -> Void] {
            guard let dict = subscribers[type] else { return [] }
            return Array(dict.values)
        }
    }

    private let storage = Storage()

    /// Subscribes to events of the specified type.
    @discardableResult
    func subscribe<E: Event>(_ type: E.Type, handler: @escaping (E) async -> Void) async -> SubscriptionToken {
        let token = SubscriptionToken()
        let wrappedHandler: (Any) async -> Void = { anyEvent in
            guard let event = anyEvent as? E else { return }
            await handler(event)
        }
        await storage.add(type: ObjectIdentifier(type), token: token, handler: wrappedHandler)
        return token
    }

    /// Unsubscribes from an event using the given subscription token.
    func unsubscribe(_ token: SubscriptionToken) async {
        await storage.remove(token: token)
    }

    /// Publishes an event to all subscribers of its type.
    func publish<E: Event>(_ event: E) async {
        let handlers = await storage.snapshotHandlers(for: ObjectIdentifier(E.self))
        for handler in handlers {
            await handler(event)
        }
    }
}

/// An event signaling a user has joined a voice channel.
struct VoiceJoined: Event {
    let guildId: String
    let userId: String
    let username: String
    let channelId: String
}

/// An event signaling a user has left a voice channel.
struct VoiceLeft: Event {
    let guildId: String
    let userId: String
    let username: String
    let channelId: String
    let durationSeconds: Int
}

/// An event signaling that a message was received.
struct MessageReceived: Event {
    let guildId: String?
    let channelId: String
    let userId: String
    let username: String
    let content: String
    let isDirectMessage: Bool
}
