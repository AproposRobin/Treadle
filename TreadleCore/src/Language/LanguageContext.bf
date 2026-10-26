using System;
using Treadle.Catalog;
using Treadle.Document;
using Treadle.Format;

namespace Treadle.Language
{
	/// The language's facade for one workspace: the one object the shell asks about types, nodes,
	/// files and builds (the seams in Seams.bf and Toolchain.bf). The editor makes one context and
	/// hands it to its documents; a document passes it down to every graph it holds.
	///
	/// A context owns its default (null) services and nothing else: a language that installs its own
	/// services deletes them itself, after the documents that point at the context. Every service
	/// member is always non-null, so callers never check.
	class LanguageContext
	{
		public const String DefaultId = "treadle";

		/// The language's id.
		public StringView Id => DefaultId;

		NullTypeSystem mNullTypes = new .() ~ delete _;
		EmptyNodeCatalogSource mEmptyCatalog = new .() ~ delete _;
		NullGraphCodec mNullCodec = new .() ~ delete _;
		/// The record format (Graph-Format.md): installed by default, it is the program source.
		TreadleCodec mCodec = new .() ~ delete _;
		NoLanguageRules mNoRules = new .() ~ delete _;

		/// Type queries: pin colours, wire checks, value controls, enum members, defaults.
		public ITypeSystem Types;
		/// The entries of the Node menu.
		public INodeCatalogSource Catalog;
		/// The graph file format.
		public IGraphCodec Codec;
		/// The checks a Sheet has to pass before it is written.
		public ILanguageRules Rules;
		/// The project's files (the Project Browser, Find in Sheets). Not owned; may be null.
		public ProjectIndex Index;
		/// Validate, Build and Run. Not owned; null where nothing builds.
		public IToolchain Toolchain;

		/// Class hierarchies for conversions and pin families (TypeRules asks it).
		public ITypeHierarchy Hierarchy => Types;

		public this()
		{
			Types = mNullTypes;
			Catalog = mEmptyCatalog;
			Codec = mCodec;
			Rules = mNoRules;
		}

		/// `ctx?.Types` for callers that hold a possibly null context.
		public static ITypeSystem TypesOf(LanguageContext ctx) => (ctx != null) ? ctx.Types : null;

		/// `ctx?.Index` for callers that hold a possibly null context.
		public static ProjectIndex IndexOf(LanguageContext ctx) => (ctx != null) ? ctx.Index : null;

		/// `ctx?.Hierarchy` for callers that hold a possibly null context.
		public static ITypeHierarchy HierarchyOf(LanguageContext ctx) => (ctx != null) ? ctx.Hierarchy : null;
	}
}
