import Foundation

/// UI text in Spanish (the source language), English, French, Italian and
/// Portuguese. The language follows macOS (System Settings › Language &
/// Region, including the per-app setting); anything else falls back to English.
enum L10n {
    static let languages = ["es", "en", "fr", "it", "pt"]

    static let current: String = {
        for id in Locale.preferredLanguages {
            let code = String(id.prefix(2)).lowercased()
            if languages.contains(code) { return code }
        }
        return "en"
    }()

    /// Spanish source text → [en, fr, it, pt].
    static let table: [String: [String]] = [
        // Room titles
        "TRABAJANDO": ["WORKING", "AU TRAVAIL", "AL LAVORO", "TRABALHANDO"],
        "ATENCIÓN": ["ATTENTION", "ATTENTION", "ATTENZIONE", "ATENÇÃO"],
        "EN ESPERA": ["WAITING", "EN ATTENTE", "IN ATTESA", "EM ESPERA"],
        "LISTO": ["DONE", "TERMINÉ", "FATTO", "PRONTO"],
        "SIN ESTADO": ["NO STATUS", "SANS ÉTAT", "SENZA STATO", "SEM ESTADO"],
        // Status labels
        "Trabajando": ["Working", "Au travail", "Al lavoro", "Trabalhando"],
        "Necesita atención": ["Needs attention", "Demande ton attention", "Richiede attenzione", "Precisa de atenção"],
        "En espera": ["Waiting", "En attente", "In attesa", "Em espera"],
        "Listo": ["Done", "Terminé", "Fatto", "Pronto"],
        "Sin estado": ["No status", "Sans état", "Senza stato", "Sem estado"],
        // Window, menu and status item
        "Minimizar (ocultar)": ["Minimize (hide)", "Réduire (masquer)", "Riduci (nascondi)", "Minimizar (ocultar)"],
        "Cerrar": ["Close", "Fermer", "Chiudi", "Fechar"],
        "Arrastrar para mover": ["Drag to move", "Glisser pour déplacer", "Trascina per spostare", "Arraste para mover"],
        "Mostrar / ocultar": ["Show / hide", "Afficher / masquer", "Mostra / nascondi", "Mostrar / ocultar"],
        "Reposicionar en la esquina": ["Move back to the corner", "Replacer dans le coin", "Riposiziona nell'angolo", "Reposicionar no canto"],
        "Acerca de Herdr Pixel Dungeon": ["About Herdr Pixel Dungeon", "À propos de Herdr Pixel Dungeon", "Informazioni su Herdr Pixel Dungeon", "Sobre o Herdr Pixel Dungeon"],
        "Salir": ["Quit", "Quitter", "Esci", "Sair"],
        "Herdr Pixel Dungeon · %ld necesitan atención": ["Herdr Pixel Dungeon · %ld need attention", "Herdr Pixel Dungeon · %ld demandent ton attention",
                                                        "Herdr Pixel Dungeon · %ld richiedono attenzione", "Herdr Pixel Dungeon · %ld precisam de atenção"],
        "Creado por Nacho Valencia.\nCódigo y pixel art originales · MIT.":
            ["Created by Nacho Valencia.\nOriginal code and pixel art · MIT.",
             "Créé par Nacho Valencia.\nCode et pixel art originaux · MIT.",
             "Creato da Nacho Valencia.\nCodice e pixel art originali · MIT.",
             "Criado por Nacho Valencia.\nCódigo e pixel art originais · MIT."],
        // Sounds and chat
        "↑↓ y ⏎ eligen · o responde a %@…": ["↑↓ and ⏎ choose · or reply to %@…", "↑↓ et ⏎ choisissent · ou réponds à %@…", "↑↓ e ⏎ scelgono · o rispondi a %@…", "↑↓ e ⏎ escolhem · ou responda a %@…"],
        "Finalizar agente (/exit)": ["End agent (/exit)", "Terminer l’agent (/exit)", "Termina l’agente (/exit)", "Encerrar agente (/exit)"],
        "¿Finalizar %@?": ["End %@?", "Terminer %@ ?", "Terminare %@?", "Encerrar %@?"],
        "Se escribirá /exit en su chat de Herdr.": ["/exit will be typed into its chat in Herdr.", "/exit sera tapé dans son chat dans Herdr.", "/exit verrà scritto nella sua chat in Herdr.", "/exit será digitado no chat dele no Herdr."],
        "Finalizar": ["End", "Terminer", "Termina", "Encerrar"],
        "Cancelar": ["Cancel", "Annuler", "Annulla", "Cancelar"],
        "Herdr rechazó la acción. Revisa el panel del agente.": ["Herdr refused the action. Check the agent’s pane.", "Herdr a refusé l’action. Vérifie le panneau de l’agent.", "Herdr ha rifiutato l’azione. Controlla il pannello dell’agente.", "O Herdr recusou a ação. Verifique o painel do agente."],
        "Tú → %@: %@": ["You → %@: %@", "Toi → %@ : %@", "Tu → %@: %@", "Você → %@: %@"],
        "Sonidos": ["Sounds", "Sons", "Suoni", "Sons"],
        "Sonidos activados": ["Sounds on", "Sons activés", "Suoni attivi", "Sons ativados"],
        "Al necesitar ayuda": ["When help is needed", "Quand il faut de l’aide", "Quando serve aiuto", "Ao precisar de ajuda"],
        "Al terminar": ["When finished", "À la fin", "Al termine", "Ao terminar"],
        "Silenciar sonidos": ["Mute sounds", "Couper les sons", "Silenzia i suoni", "Silenciar sons"],
        "Activar sonidos": ["Turn sounds on", "Activer les sons", "Attiva i suoni", "Ativar sons"],
        "Enfocar este agente en Herdr": ["Focus this agent in Herdr", "Afficher cet agent dans Herdr", "Metti a fuoco questo agente in Herdr", "Focar este agente no Herdr"],
        "Leyendo la terminal…": ["Reading the terminal…", "Lecture du terminal…", "Leggo il terminale…", "Lendo o terminal…"],
        "Escribir a %@…": ["Write to %@…", "Écrire à %@…", "Scrivi a %@…", "Escrever para %@…"],
        "Enviar (⏎)": ["Send (⏎)", "Envoyer (⏎)", "Invia (⏎)", "Enviar (⏎)"],
        "Aceptar": ["Accept", "Accepter", "Accetta", "Aceitar"],
        "Elegir la opción marcada del agente (⏎ en su terminal)": ["Choose the agent’s highlighted option (⏎ in its terminal)", "Choisir l’option sélectionnée de l’agent (⏎ dans son terminal)", "Scegli l’opzione evidenziata dell’agente (⏎ nel suo terminale)", "Escolher a opção marcada do agente (⏎ no terminal dele)"],
        "Rechazar": ["Decline", "Refuser", "Rifiuta", "Recusar"],
        "Cancelar la petición del agente (esc en su terminal)": ["Cancel the agent’s request (esc in its terminal)", "Annuler la demande de l’agent (esc dans son terminal)", "Annulla la richiesta dell’agente (esc nel suo terminale)", "Cancelar o pedido do agente (esc no terminal dele)"],
        "Detener": ["Stop", "Arrêter", "Ferma", "Parar"],
        "Interrumpir al agente (esc en su terminal)": ["Interrupt the agent (esc in its terminal)", "Interrompre l’agent (esc dans son terminal)", "Interrompi l’agente (esc nel suo terminale)", "Interromper o agente (esc no terminal dele)"],
        "Sin agentes en la sesión": ["No agents in this session", "Aucun agent dans la session", "Nessun agente nella sessione", "Nenhum agente na sessão"],
        // Herdr connection
        "Herdr no entregó un snapshot válido.": ["Herdr did not return a valid snapshot.", "Herdr n'a pas renvoyé d'instantané valide.",
                                                 "Herdr non ha restituito uno snapshot valido.", "O Herdr não retornou um snapshot válido."],
        "No se encontró Herdr. Instálalo o define HERDR_BIN.": ["Herdr not found. Install it or set HERDR_BIN.", "Herdr introuvable. Installe-le ou définis HERDR_BIN.",
                                                                "Herdr non trovato. Installalo o imposta HERDR_BIN.", "Herdr não encontrado. Instale-o ou defina HERDR_BIN."],
        "Sin conexión con Herdr. Abre tu sesión; reintentamos automáticamente.":
            ["No connection to Herdr. Open your session; we retry automatically.",
             "Pas de connexion à Herdr. Ouvre ta session ; nouvel essai automatique.",
             "Nessuna connessione a Herdr. Apri la tua sessione; riproviamo automaticamente.",
             "Sem conexão com o Herdr. Abra sua sessão; tentamos de novo automaticamente."],
        "Sin título de actividad": ["No activity title", "Aucun titre d'activité", "Nessun titolo di attività", "Sem título de atividade"],
        // Events
        "Guild conectada · %ld agentes": ["Guild connected · %ld agents", "Guilde connectée · %ld agents", "Gilda connessa · %ld agenti", "Guilda conectada · %ld agentes"],
        "%@ · %ld subagentes activos": ["%@ · %ld active subagents", "%@ · %ld sous-agents actifs", "%@ · %ld subagenti attivi", "%@ · %ld subagentes ativos"],
        "%@ entró a la guild": ["%@ joined the guild", "%@ a rejoint la guilde", "%@ è entrato nella gilda", "%@ entrou na guilda"],
        "%@ salió de la guild": ["%@ left the guild", "%@ a quitté la guilde", "%@ ha lasciato la gilda", "%@ saiu da guilda"],
        // HUD: filters and search
        "Ningún agente coincide": ["No agent matches", "Aucun agent ne correspond", "Nessun agente corrisponde", "Nenhum agente corresponde"],
        "Todos": ["All", "Tous", "Tutti", "Todos"],
        "Buscar…": ["Search…", "Rechercher…", "Cerca…", "Buscar…"],
        "Cerrar búsqueda (esc)": ["Close search (esc)", "Fermer la recherche (esc)", "Chiudi ricerca (esc)", "Fechar busca (esc)"],
        "Buscar por proyecto, agente, rama, carpeta o actividad": ["Search by project, agent, branch, folder or activity", "Rechercher par projet, agent, branche, dossier ou activité",
                                                                 "Cerca per progetto, agente, branch, cartella o attività", "Buscar por projeto, agente, branch, pasta ou atividade"],
        // Notifications
        "%@ necesita atención": ["%@ needs attention", "%@ demande ton attention", "%@ richiede attenzione", "%@ precisa de atenção"],
        "%@ terminó": ["%@ finished", "%@ a terminé", "%@ ha finito", "%@ terminou"],
        "Notificaciones": ["Notifications", "Notifications", "Notifiche", "Notificações"],
        "Notificaciones activadas": ["Notifications on", "Notifications activées", "Notifiche attive", "Notificações ativadas"],
        // Activity log
        "Registro de actividad": ["Activity log", "Journal d’activité", "Registro attività", "Registro de atividade"],
        "Registro de la guild": ["Guild log", "Journal de la guilde", "Registro della gilda", "Registro da guilda"],
        "Aún no pasa nada.": ["Nothing has happened yet.", "Rien ne s’est encore passé.", "Non è ancora successo nulla.", "Nada aconteceu ainda."],
        // Demo activity titles
        "Construyendo la página de ajustes": ["Building the settings page", "Construction de la page des réglages", "Costruisco la pagina delle impostazioni", "Construindo a página de ajustes"],
        "Revisando las pruebas": ["Reviewing the tests", "Révision des tests", "Rivedo i test", "Revisando os testes"],
        "Esperando tu respuesta": ["Waiting for your answer", "En attente de ta réponse", "In attesa della tua risposta", "Aguardando sua resposta"],
        "Listo para la próxima tarea": ["Ready for the next task", "Prêt pour la prochaine tâche", "Pronto per il prossimo compito", "Pronto para a próxima tarefa"],
        "Documentación actualizada": ["Documentation updated", "Documentation à jour", "Documentazione aggiornata", "Documentação atualizada"],
        "Ajustando el movimiento": ["Tuning the movement", "Réglage du mouvement", "Regolo il movimento", "Ajustando o movimento"],
    ]

    static func text(_ spanish: String, language: String = current) -> String {
        guard language != "es", let index = languages.firstIndex(of: language),
              let row = table[spanish], index - 1 < row.count else { return spanish }
        return row[index - 1]
    }
}

/// Translate a Spanish UI string, formatting it with `args` when given.
func tr(_ spanish: String, _ args: CVarArg...) -> String {
    let text = L10n.text(spanish)
    return args.isEmpty ? text : String(format: text, arguments: args)
}
