import Foundation

/// As cores de conta, em par claro/escuro.
///
/// **Cicla, e não acaba.** Uma lista com fim daria à décima primeira conta uma
/// cor nula ou um `precondition` — e o número de contas é ilimitado por
/// restrição herdada. Repetir cor na décima primeira é um incômodo visual;
/// recusar a décima primeira conta é um defeito.
///
/// Os pares são os das fixtures do Marco 1 mais os que o design usa nos temas,
/// já convertidos para sRGB.
public enum AccountTints {
    private static let pairs: [(light: String, dark: String)] = [
        ("#3F6AA1", "#8CBAF7"),
        ("#725B9A", "#C2A7F4"),
        ("#397852", "#88D1A2"),
        ("#298084", "#71D0D5"),
        ("#9A5B5B", "#F4A7A7"),
        ("#8A6D2F", "#E5C371"),
        ("#4A5B9A", "#A7B4F4"),
        ("#5B9A6D", "#A7F4C3"),
    ]

    /// O par da n-ésima conta. Índice negativo também tem cor: o resto de
    /// `%` em Swift herda o sinal do dividendo, e um `-1` cru estouraria o
    /// índice em vez de dar a volta.
    public static func pair(forIndex index: Int) -> (light: String, dark: String) {
        pairs[((index % pairs.count) + pairs.count) % pairs.count]
    }
}
