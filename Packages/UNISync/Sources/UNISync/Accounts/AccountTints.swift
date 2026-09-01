import Foundation
import UNICore

/// As cores de conta, em par claro/escuro.
///
/// **Cicla, e não acaba.** Uma lista com fim daria à conta seguinte uma cor
/// nula ou um `precondition` — e o número de contas é ilimitado por restrição
/// herdada. Repetir cor depois do catálogo é um incômodo visual; recusar a
/// conta é um defeito.
///
/// Os pares são `AccountTint.catalogue` em UNICore, a mesma lista do menu
/// "Cor da caixa".
public enum AccountTints {
    public static var count: Int { AccountTint.count }

    public static func pair(forIndex index: Int) -> (light: String, dark: String) {
        AccountTint.pair(forIndex: index)
    }
}
