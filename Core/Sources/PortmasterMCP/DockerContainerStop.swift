// DockerContainerStop: stopping a container, once, for every provider.
//
// `stop_container` is one tool, reachable through two providers — the on-demand one
// and the app-hosted one — and both refuse with the same sentences. A stop that has
// to refuse (docker absent, daemon down, unknown id, docker CLI gone between the
// sample and the command) or that has to report what docker said must therefore also
// be one implementation: two copies would agree on the argv today and drift on the
// wording the first time one of them is edited.
//
// What is *not* shared is where the reading came from. Each provider resolves its
// own — `OnDemandProvider` collects one on demand, the app reads what its sampler has
// published — and each refuses "not known yet" in its own words before coming here.
//
// Not through the process list, and that is deliberate: a reading has no
// container-to-pid attribution, and matching a container to a same-named process
// would be a guess about something the caller then acts on. So this runs the one
// command that stops a container — `docker stop -- <id>`, fixed argv, the id as
// exactly one element and after `--` so an id that starts with `-` cannot be read as
// a flag. No shell is involved, so shell metacharacters in an id are characters, not
// commands.

import Foundation
import PortmasterCore

/// The docker stop every provider performs, with every refusal it can raise.
public enum DockerContainerStop {

    /// `docker stop` waits for the container's own grace period, so this is
    /// generous; it exists to stop a call hanging forever, not to hurry docker.
    static let timeout: TimeInterval = 20

    /// Stops `id`, or throws the reason it cannot.
    ///
    /// - Parameters:
    ///   - id: the container's id or name, as the caller wrote it.
    ///   - docker: the reading to check `id` against. A nil reading is the caller's
    ///     refusal to make, not this function's: it has no way to know what has not
    ///     been observed.
    ///   - runner: how the command runs. Injected so a test asserts argv and outcome
    ///     without a docker daemon, a container or a binary.
    ///   - executable: where the docker CLI is, resolved through the collector's own
    ///     candidate list unless a caller supplies it. Called only after the sample
    ///     said docker was there.
    public static func stop(
        container id: String,
        in docker: DockerSample,
        runner: any ProcessRunning = SystemProcessRunner(),
        executable: @escaping @Sendable () -> String? = { DockerCollector.locate() }
    ) async throws -> StopReport {
        if let refusal = refusal(container: id, in: docker) { throw refusal }
        guard let path = executable() else {
            // The sample said docker was there; it is not now.
            throw OnDemandProvider.dockerCommandUnavailableMessage(container: id)
        }

        let outcome: CommandOutcome
        do {
            outcome = try await runner.run(
                executable: path,
                arguments: ["stop", "--", id],
                timeout: timeout
            )
        } catch {
            throw MCPToolError.wrapping(error, subsystem: "docker")
        }
        // Formatted through `StopReport` so a container stop and a pid stop read
        // the same way in the payload. The outcome is docker's own: exit 0 is a stop,
        // a non-zero exit is reported with what docker said.
        let status: StopCoordinator.Outcome.Status = outcome.exitCode == 0
            ? .stopped
            : .failed(message: failureMessage(outcome))
        return StopReport(results: [id: StopReport.value(for: status)])
    }

    /// Why `id` cannot be stopped against `docker`, or `nil` when it can.
    ///
    /// Split out of `stop` so the same question can be asked *before* anything runs:
    /// the app's confirmation window asks it to decide whether a person should be troubled
    /// with the request at all. One implementation, because a pre-check that disagreed
    /// with the stop would either ask about a container that is not there, or refuse one
    /// that is.
    ///
    /// Availability first: with the daemon down or docker absent there is no container
    /// list to match against, and no stop to attempt. The missing-CLI case is *not*
    /// answered here — that one needs a lookup this function does not make, so it stays
    /// in `stop`.
    public static func refusal(container id: String, in docker: DockerSample) -> MCPToolError? {
        if let refusal = OnDemandProvider.dockerUnavailableMessage(
            docker.availability, container: id
        ) {
            return refusal
        }
        guard docker.containers.contains(where: { $0.id == id || $0.name == id }) else {
            return OnDemandProvider.containerNotFound(id)
        }
        return nil
    }

    /// Docker's own explanation, first line, or the exit status when docker said
    /// nothing. Never replaced with a guess about what went wrong.
    static func failureMessage(_ outcome: CommandOutcome) -> String {
        let firstLine = outcome.standardError
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let firstLine, !firstLine.isEmpty else {
            return "docker exited with status \(outcome.exitCode) and said nothing."
        }
        return firstLine
    }
}
