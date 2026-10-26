#if !TREADLE_SELFTEST
namespace Treadle.Editor
{
	/// The package build (the ReleasePackage configuration, without the TREADLE_SELFTEST define;
	/// docs/Releasing.md): the developer self tests are not compiled in. These stand in for the few
	/// members the editor's frame loop reads.
	extension EditorApp
	{
		/// No self test is running (the self tests' own value for "none").
		const int mSelfTestStep = -2;

		void SelfTestTick()
		{
		}
	}
}
#endif
