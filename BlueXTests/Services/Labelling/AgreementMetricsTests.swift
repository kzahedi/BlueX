import XCTest
@testable import BlueX

final class AgreementMetricsTests: XCTestCase {
    /// Hand-worked 10-item example, two classes "A"/"B":
    ///
    ///   uri   pass1  pass2   agree?
    ///   1     A      A       yes
    ///   2     A      A       yes
    ///   3     A      A       yes
    ///   4     A      B       no
    ///   5     A      A       yes
    ///   6     B      B       yes
    ///   7     B      A       no
    ///   8     B      B       yes
    ///   9     B      B       yes
    ///   10    B      B       yes
    ///
    /// po = 8/10 = 0.8 (8 agreements out of 10 pairs).
    /// pass1 marginals: A appears in {1,2,3,4,5} → m1(A) = 5/10 = 0.5; B in {6..10} → m1(B) = 0.5.
    /// pass2 marginals: A appears in {1,2,3,5,7} → m2(A) = 5/10 = 0.5; B in {4,6,8,9,10} → m2(B) = 0.5.
    /// pe = m1(A)*m2(A) + m1(B)*m2(B) = 0.5*0.5 + 0.5*0.5 = 0.25 + 0.25 = 0.5.
    /// kappa = (po - pe) / (1 - pe) = (0.8 - 0.5) / (1 - 0.5) = 0.3 / 0.5 = 0.6.
    func testHandWorkedTenItemExample() throws {
        let pass1: [String: String] = [
            "at://1": "A", "at://2": "A", "at://3": "A", "at://4": "A", "at://5": "A",
            "at://6": "B", "at://7": "B", "at://8": "B", "at://9": "B", "at://10": "B",
        ]
        let pass2: [String: String] = [
            "at://1": "A", "at://2": "A", "at://3": "A", "at://4": "B", "at://5": "A",
            "at://6": "B", "at://7": "A", "at://8": "B", "at://9": "B", "at://10": "B",
        ]
        let report = try XCTUnwrap(AgreementMetrics.compute(pass1: pass1, pass2: pass2))
        XCTAssertEqual(report.n, 10)
        XCTAssertEqual(report.percentAgreement, 0.8, accuracy: 1e-9)
        XCTAssertEqual(report.cohensKappa, 0.6, accuracy: 1e-9)
    }

    /// Perfect agreement across two classes (not the single-class degenerate case):
    /// po = 1, m1(A)=m2(A)=0.5, m1(B)=m2(B)=0.5, pe = 0.5 → kappa = (1-0.5)/(1-0.5) = 1.
    func testPerfectAgreementAcrossTwoClassesGivesKappaOne() throws {
        let pass1 = ["at://1": "A", "at://2": "B"]
        let pass2 = ["at://1": "A", "at://2": "B"]
        let report = try XCTUnwrap(AgreementMetrics.compute(pass1: pass1, pass2: pass2))
        XCTAssertEqual(report.percentAgreement, 1.0, accuracy: 1e-9)
        XCTAssertEqual(report.cohensKappa, 1.0, accuracy: 1e-9)
    }

    /// Single-class degenerate case: every pair uses the same class, so pe == 1 and the
    /// textbook kappa formula would divide by zero. Perfect agreement here must still
    /// report kappa == 1, not NaN/infinity.
    func testSingleClassDegenerateCaseDoesNotDivideByZero() throws {
        let pass1 = ["at://1": "A", "at://2": "A", "at://3": "A"]
        let pass2 = ["at://1": "A", "at://2": "A", "at://3": "A"]
        let report = try XCTUnwrap(AgreementMetrics.compute(pass1: pass1, pass2: pass2))
        XCTAssertEqual(report.percentAgreement, 1.0, accuracy: 1e-9)
        XCTAssertFalse(report.cohensKappa.isNaN)
        XCTAssertFalse(report.cohensKappa.isInfinite)
        XCTAssertEqual(report.cohensKappa, 1.0, accuracy: 1e-9)
    }

    /// Disjoint URI sets share no keys to pair up — there is nothing to measure
    /// agreement over, so this must return `nil` rather than a report over zero pairs.
    func testDisjointURISetsReturnNil() {
        let pass1 = ["at://1": "A"]
        let pass2 = ["at://2": "A"]
        XCTAssertNil(AgreementMetrics.compute(pass1: pass1, pass2: pass2))
    }
}
