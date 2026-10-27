import Foundation

/// The emoji offered by DeskDrop's emoji keyboard, by category. Search uses each
/// emoji's Unicode name, so "heart", "thumbs" or "cat" find what you'd expect.
enum EmojiCatalog {
    enum Category: String, CaseIterable, Identifiable {
        case recent, smileys, people, hearts, nature, food, activities, travel, objects, symbols

        var id: String { rawValue }

        var title: String {
            switch self {
            case .recent: String(localized: "Frequently Used")
            case .smileys: String(localized: "Smileys")
            case .people: String(localized: "People & Gestures")
            case .hearts: String(localized: "Hearts & Feelings")
            case .nature: String(localized: "Animals & Nature")
            case .food: String(localized: "Food & Drink")
            case .activities: String(localized: "Activities")
            case .travel: String(localized: "Travel & Places")
            case .objects: String(localized: "Objects")
            case .symbols: String(localized: "Symbols")
            }
        }

        var symbolName: String {
            switch self {
            case .recent: "clock"
            case .smileys: "face.smiling"
            case .people: "hand.wave"
            case .hearts: "heart"
            case .nature: "leaf"
            case .food: "fork.knife"
            case .activities: "soccerball"
            case .travel: "car"
            case .objects: "lightbulb"
            case .symbols: "number"
            }
        }
    }

    /// The tapbacks shown first when reacting, as in Messages.
    static let tapbacks = ["❤️", "👍", "👎", "😂", "‼️", "❓"]

    static func emoji(in category: Category) -> [String] {
        switch category {
        case .recent: []
        case .smileys: smileys
        case .people: people
        case .hearts: hearts
        case .nature: nature
        case .food: food
        case .activities: activities
        case .travel: travel
        case .objects: objects
        case .symbols: symbols
        }
    }

    static var all: [String] {
        unique(Category.allCases.flatMap(emoji(in:)))
    }

    /// Emoji whose Unicode names contain every word of `query`.
    static func search(_ query: String) -> [String] {
        let words = query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return [] }
        return all.filter { emoji in
            let name = emoji.unicodeScalars.compactMap { $0.properties.name?.lowercased() }.joined(separator: " ")
            return words.allSatisfy { name.contains($0) }
        }
    }

    private static func list(_ characters: String) -> [String] {
        unique(characters.map(String.init))
    }

    private static func unique(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { seen.insert($0).inserted }
    }

    private static let smileys = list("😀😃😄😁😆😅🤣😂🙂🙃🫠😉😊😇🥰😍🤩😘😗😚😙🥲😋😛😜🤪😝🤑🤗🤭🫢🫣🤫🤔🫡🤐🤨😐😑😶🫥😏😒🙄😬😮‍💨🤥😌😔😪🤤😴😷🤒🤕🤢🤮🤧🥵🥶🥴😵🤯🤠🥳🥸😎🤓🧐😕🫤😟🙁😮😯😲😳🥺🥹😦😧😨😰😥😢😭😱😖😣😞😓😩😫🥱😤😡😠🤬😈👿💀☠️💩🤡👻👽🤖😺😸😹😻😼😽🙀😿😾")
    private static let people = list("👋🤚🖐️✋🖖🫱🫲👌🤌🤏✌️🤞🫰🤟🤘🤙👈👉👆👇☝️🫵👍👎✊👊🤛🤜👏🙌🫶👐🤲🤝🙏✍️💅🤳💪🧠👀👁️👅👄🫦👶🧒👦👧🧑👱👨🧔👩🧓👴👵🙋🙆🙅🤷🤦🙇💁🧑‍💻👨‍💻👩‍💻🧑‍🍳🕺💃")
    private static let hearts = list("❤️🧡💛💚💙🩵💜🤎🖤🩶🤍💔❤️‍🔥❤️‍🩹❣️💕💞💓💗💖💘💝💟💌💋💯💢💥💫💦💨💬💭💤")
    private static let nature = list("🐶🐱🐭🐹🐰🦊🐻🐼🐨🐯🦁🐮🐷🐸🐵🙈🙉🙊🐔🐧🐦🐤🦆🦅🦉🦇🐺🐗🐴🦄🐝🐛🦋🐌🐞🐢🐍🦎🐙🦑🦀🐡🐠🐟🐬🐳🐋🦈🐊🐅🦓🦍🐘🦒🦘🐄🐎🐑🐐🦌🐕🐈🐓🦚🦜🦢🦩🕊️🐇🦝🦦🦥🐿️🦔🌵🎄🌲🌳🌴🌱🌿☘️🍀🍃🍂🍁🍄🌾💐🌷🌹🥀🌺🌸🌼🌻🌞🌝🌛🌙🌎⭐🌟✨⚡🔥🌈☀️⛅☁️🌧️⛈️❄️☃️🌊")
    private static let food = list("🍏🍎🍐🍊🍋🍌🍉🍇🍓🫐🍒🍑🥭🍍🥥🥝🍅🍆🥑🥦🥒🌶️🌽🥕🧄🧅🥔🥐🥯🍞🥖🥨🧀🥚🍳🧈🥞🧇🥓🥩🍗🍖🌭🍔🍟🍕🥪🥙🌮🌯🥗🥘🍝🍜🍲🍛🍣🍱🥟🍤🍙🍚🍘🍥🥠🍢🍡🍧🍨🍦🥧🧁🍰🎂🍮🍭🍬🍫🍿🍩🍪🌰🥜🍯🥛☕🫖🍵🧃🥤🧋🍶🍺🍻🥂🍷🥃🍸🍹🧉🍾🧊")
    private static let activities = list("⚽🏀🏈⚾🥎🎾🏐🏉🥏🎱🏓🏸🏒🏏⛳🪁🏹🎣🤿🥊🥋🛹⛸️🎿🏂🏋️🤸🧘🏄🏊🚴🏆🥇🥈🥉🏅🎖️🎫🎟️🎪🎭🎨🎬🎤🎧🎼🎹🥁🎷🎺🎸🎻🎲♟️🎯🎳🎮🧩🎉🎊🎈🎁🎀")
    private static let travel = list("🚗🚕🚙🚌🏎️🚓🚑🚒🚐🛻🚚🚜🛵🏍️🚲🛴🚨🚍🚄🚅🚂🚆🚇🚊✈️🛫🛬🚀🛸🚁🛶⛵🚤🛳️🚢⚓⛽🚧🚦🗺️🗿🗽🗼🏰🏯🏟️🎡🎢🎠⛲🏖️🏝️🏜️🌋⛰️🏔️🗻🏕️⛺🏠🏡🏢🏬🏥🏦🏨🏪🏫🏛️⛪🕌🌅🌄🌠🎇🎆🌇🌆🏙️🌃🌌🌉")
    private static let objects = list("⌚📱💻⌨️🖥️🖨️🖱️🕹️💾💿📷📸📹🎥📞☎️📺📻🎙️⏱️⏰⌛⏳📡🔋🔌💡🔦🕯️💸💵💰💳💎⚖️🧰🔧🔨🛠️🔩⚙️🧲💣🧨🔪🛡️🔮💈🔭🔬🩹🩺💊💉🧬🦠🧪🌡️🧹🧺🧻🧼🧽🛎️🔑🗝️🚪🪑🛋️🛏️🧸🖼️🛍️🛒📦📫📮📝📁📂📅📆🗒️📇📈📉📊📋📌📍📎🖇️📏📐✂️🗃️🗄️🗑️🔒🔓🔐🖊️🖋️✒️🖌️🖍️📒📕📗📘📙📚📖🔖🧷🔗")
    private static let symbols = list("✅☑️✔️❌❎➕➖➗✖️♾️‼️⁉️❓❔❕❗〰️💲⚕️♻️⚜️🔱📛🔰⭕✳️❇️🆗🆙🆒🆕🆓🔝🔜▶️⏸️⏯️⏹️⏺️⏭️⏮️⏩⏪🔀🔁🔂◀️🔼🔽➡️⬅️⬆️⬇️↗️↘️↙️↖️↕️↔️↪️↩️⤴️⤵️🔄🔃🎵🎶™️©️®️🔘🔴🟠🟡🟢🔵🟣⚫⚪🟤🔺🔻🔸🔹🔶🔷🟥🟧🟨🟩🟦🟪⬛⬜🟫🔈🔇🔉🔊🔔🔕📣📢♠️♣️♥️♦️🃏🀄")
}
