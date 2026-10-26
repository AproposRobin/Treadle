using System;
using System.Collections;
using System.Diagnostics;
using Treadle.Language;

namespace Treadle.Catalog
{
	enum NodeEntryKind : uint8
	{
		Call,   // a node with flow pins
		Pure,   // a node without flow pins
		Get,    // read a variable / field
		Set,    // write a variable / field
		Event,  // an event (bind / invoke)
		Flow    // one flow output per case of an enum
	}

	/// One pin of a node spec.
	class PinSpec
	{
		public String Name = new .() ~ delete _;     // stable pin name
		public String Label = new .() ~ delete _;    // shown on the pin
		public String Type = new .() ~ delete _;
		public String Default = new .() ~ delete _;  // the value an unwired input starts with
		public String Tooltip = new .() ~ delete _;
		public String Modifier = new .() ~ delete _; // ref / out / params
		public bool Advanced;
		/// A `ref` parameter shown as an output pin like `out`.
		public bool OutRef;
		/// The callback parameter of a callback node.
		public bool IsCallback;

		/// The parameter is an output of the node: `out`, or `ref` marked OutRef.
		public bool IsOutput => OutRef || IsOutModifier(Modifier);
		public bool IsRef => !OutRef && HasWord(Modifier, "ref");

		public static bool IsOutModifier(StringView modifier) => HasWord(modifier, "out");

		public static bool HasWord(StringView text, StringView word)
		{
			for (var part in text.Split(' '))
			{
				part.Trim();
				if (part == word)
					return true;
			}
			return false;
		}

		public void CopyFrom(PinSpec o)
		{
			Name.Set(o.Name);
			Label.Set(o.Label);
			Type.Set(o.Type);
			Default.Set(o.Default);
			Tooltip.Set(o.Tooltip);
			Modifier.Set(o.Modifier);
			Advanced = o.Advanced;
			OutRef = o.OutRef;
			IsCallback = o.IsCallback;
		}
	}

	/// Everything the editor needs to show and create one catalog entry. The language's catalog
	/// source (`INodeCatalogSource`, a seam) fills these.
	class NodeSpec
	{
		public int32 Id = -1;
		public NodeEntryKind Kind;
		public String Label = new .() ~ delete _;        // menu text
		public String DisplayName = new .() ~ delete _;
		/// "Math | Vector": the category path, segments joined with '|'.
		public String Category = new .() ~ delete _;
		public String Keywords = new .() ~ delete _;
		public String Tooltip = new .() ~ delete _;
		/// What the node calls or reads: the language's name for it.
		public String CallName = new .() ~ delete _;
		public String MemberName = new .() ~ delete _;
		public String OwnerType = new .() ~ delete _;
		public String Namespace = new .() ~ delete _;
		public String ReturnType = new .() ~ delete _;    // value type for Get/Set
		public String ParamsText = new .() ~ delete _;
		public List<PinSpec> Pins = new .() ~ DeleteContainerAndItems!(_);
		public String ExpandEnumParam = new .() ~ delete _;
		public List<String> EnumCases = new .() ~ DeleteContainerAndItems!(_);
		public bool IsStatic;
		public bool IsConversion;
		public bool IsCompact;
		public bool IsAdvanced;
		public bool IsGeneric;
		public String CompactTitle = new .() ~ delete _;
		public bool IsCallback;
		public String CallbackRole = new .() ~ delete _;
		public String CallbackParam = new .() ~ delete _;
		/// The node kind's format word when the entry is not a call / Get / Set (`Construct`, `Local`,
		/// `Make`, `Break`, `MakeCase`, `IsCase`, `Cast`, `Switch`, any Graph-Format.md 3.2 kind); "" = by Kind.
		public String KindWord = new .() ~ delete _;
		/// The node's subject as the format writes it (a type, `Enum.Case`); "" = from CallName.
		public String Subject = new .() ~ delete _;
		/// A C function with `...` (`attr Variadic`): a Call of it takes extra inputs `va0`, `va1`, ...
		/// after its own (Language.md 2.7); the Call node offers "+ arg" for them.
		public bool IsVariadic;
		/// The generic parameters of the type a KindWord entry makes (`T,U` for `Pair`), in order:
		/// a Construct / Local of an instance puts the type's arguments for them.
		public String TypeGenerics = new .() ~ delete _;
		/// A KindWord entry's node settings as the file writes them, one `key value` per line (`lanes zyx`,
		/// `expr "float4(x)"`).
		public String Settings = new .() ~ delete _;
		/// A stand-in row the editor's own table adds until the language's catalogue source has the node
		/// (VectorCatalog): a source row with the same key replaces it.
		public bool StandIn;
		public bool IsPure => Kind == .Pure || Kind == .Get;

		/// The value of a `Settings` line (`lanes` -> `zyx`); empty when there is none.
		public StringView SettingOf(StringView key)
		{
			for (var line in Settings.Split('\n'))
			{
				line.Trim();
				if (line.StartsWith(key) && line.Length > key.Length && line[key.Length] == ' ')
					return line.Substring(key.Length + 1);
			}
			return "";
		}

		public void CopyFrom(NodeSpec o)
		{
			Settings.Set(o.Settings);
			StandIn = o.StandIn;
			Id = o.Id;
			Kind = o.Kind;
			Label.Set(o.Label);
			DisplayName.Set(o.DisplayName);
			Category.Set(o.Category);
			Keywords.Set(o.Keywords);
			Tooltip.Set(o.Tooltip);
			CallName.Set(o.CallName);
			MemberName.Set(o.MemberName);
			OwnerType.Set(o.OwnerType);
			Namespace.Set(o.Namespace);
			ReturnType.Set(o.ReturnType);
			ParamsText.Set(o.ParamsText);
			ClearAndDeleteItems!(Pins);
			for (let p in o.Pins)
			{
				let c = new PinSpec();
				c.CopyFrom(p);
				Pins.Add(c);
			}
			ExpandEnumParam.Set(o.ExpandEnumParam);
			ClearAndDeleteItems!(EnumCases);
			for (let e in o.EnumCases)
				EnumCases.Add(new String(e));
			IsStatic = o.IsStatic;
			IsConversion = o.IsConversion;
			IsCompact = o.IsCompact;
			IsAdvanced = o.IsAdvanced;
			IsGeneric = o.IsGeneric;
			CompactTitle.Set(o.CompactTitle);
			IsCallback = o.IsCallback;
			CallbackRole.Set(o.CallbackRole);
			CallbackParam.Set(o.CallbackParam);
			KindWord.Set(o.KindWord);
			Subject.Set(o.Subject);
			IsVariadic = o.IsVariadic;
			TypeGenerics.Set(o.TypeGenerics);
		}
	}

	/// A node of the category tree ("Math" > "Vector").
	class CategoryNode
	{
		public String Name = new .() ~ delete _;
		public String Path = new .() ~ delete _;
		public List<CategoryNode> Children = new .() ~ DeleteContainerAndItems!(_);
		public List<int32> Entries = new .() ~ delete _;
		/// Entries in this node and below.
		public int32 Total;

		Dictionary<StringView, CategoryNode> mByName ~ delete _;

		public CategoryNode Child(StringView name)
		{
			if (mByName == null)
				mByName = new .();
			if (mByName.TryGetValue(name, let found))
				return found;
			CategoryNode n = new .();
			n.Name.Set(name);
			if (!Path.IsEmpty)
				n.Path.AppendF("{}|", Path);
			n.Path.Append(name);
			Children.Add(n);
			mByName[n.Name] = n;
			return n;
		}
	}

	struct SearchHit
	{
		public int32 Id;
		public float Score;
	}

	/// Which pins a context-sensitive search is for.
	enum PinContext : uint8
	{
		None,
		/// Dragged from a data output: entries with an input (or receiver) that takes the type.
		TakesValue,
		/// Dragged from a data input: entries with an output of the type.
		GivesValue
	}

	/// Every node the Node menu offers beyond the built-in ones: the specs the language's catalog
	/// source hands over, with a precomputed lowercase search key per entry, fuzzy search, a
	/// context relevance per pin type and the category tree. Entry ids are the index into `Specs`
	/// and stay valid until the next `Refresh` that finds a new source generation.
	class NodeCatalog
	{
		LanguageContext mLanguage;
		public List<NodeSpec> Specs = new .() ~ DeleteContainerAndItems!(_);
		/// The lowercase search key of each spec (display name, then keywords).
		List<String> mKeys = new .() ~ DeleteContainerAndItems!(_);
		List<uint64> mMasks = new .() ~ delete _;
		public List<String> Categories = new .() ~ DeleteContainerAndItems!(_);
		Dictionary<String, int32> mCategoryIds = new .() ~ delete _;
		List<int32> mCategoryOf = new .() ~ delete _;
		int32 mGeneration = -1;
		CategoryNode mTree ~ delete _;
		/// Memo of context checks: (entry, context) -> relevance.
		Dictionary<int64, int8> mContextMemo = new .() ~ delete _;
		String mContextType = new .() ~ delete _;
		PinContext mContextKind;

		public double LastBuildMs;
		public int TotalEntries => Specs.Count;
		public int LastScanned;

		// Incremental search: what the last query matched, with the per-word scores.
		List<int32> mLastMatches = new .() ~ delete _;
		List<float> mLastFull = new .() ~ delete _;
		List<float> mLastPrefix = new .() ~ delete _;
		String mLastQuery = new .() ~ delete _;
		int mLastWordCount;
		bool mLastMatchesValid;

		public this(LanguageContext language)
		{
			mLanguage = language;
		}

		ITypeSystem Types => (mLanguage != null) ? mLanguage.Types : null;
		INodeCatalogSource Source => (mLanguage != null) ? mLanguage.Catalog : null;

		public void ResetSearchCache() => InvalidateSearchCache();

		void InvalidateSearchCache()
		{
			mLastMatchesValid = false;
			mLastMatches.Clear();
			mLastFull.Clear();
			mLastPrefix.Clear();
			mLastQuery.Clear();
			mLastWordCount = 0;
		}

		/// Rebuilds the entries when the source's generation changed.
		public void Refresh()
		{
			let source = Source;
			int32 gen = (source != null) ? source.Generation : 0;
			if (gen == mGeneration && mGeneration >= 0)
				return;
			let sw = scope Stopwatch(true);
			mGeneration = gen;
			ClearAndDeleteItems!(Specs);
			ClearAndDeleteItems!(mKeys);
			mMasks.Clear();
			ClearAndDeleteItems!(Categories);
			mCategoryIds.Clear();
			mCategoryOf.Clear();
			DeleteAndNullify!(mTree);
			mContextMemo.Clear();
			InvalidateSearchCache();
			if (source != null)
				source.Entries(Specs);
			// The vector rows of the editor's own table, where the source has none of its own yet.
			VectorCatalog.AddStandIns(Specs);
			for (int i < Specs.Count)
			{
				let s = Specs[i];
				s.Id = (int32)i;
				if (s.DisplayName.IsEmpty)
					s.DisplayName.Set(s.Label);
				String key = new .();
				Words(s.DisplayName, key);
				key.ToLower();
				let start = key.Length;
				SearchExtras(s, key);
				for (int c = start; c < key.Length; c++)
					key[c] = key[c].ToLower;
				mKeys.Add(key);
				mMasks.Add(CharMask(key));
				mCategoryOf.Add(CategoryId(s.Category));
			}
			LastBuildMs = sw.Elapsed.TotalMilliseconds;
		}

		/// What the search key holds after the display name's words, so the words a person types
		/// for an entry all find it, in any order: the keywords (the owner type's name, the Receiver
		/// of a member call: "animal speak"), the name as one word ("writeline", "mlegs"), the verb of
		/// a Get / Set row ("set mlegs"), and the types of the inputs ("writeline int").
		public static void SearchExtras(NodeSpec s, String outKey)
		{
			if (!s.Keywords.IsEmpty)
				outKey.AppendF(" {}", s.Keywords);
			StringView name = s.DisplayName;
			bool split = false;
			for (int i = 1; i < name.Length && !name.Contains(' '); i++)
				if ((name[i].IsUpper && !name[i - 1].IsUpper) || name[i] == '_')
					split = true;
			if (split)
			{
				outKey.Append(' ');
				for (let c in name.RawChars)
					if (c != '_' && c != ' ')
						outKey.Append(c);
			}
			if (s.KindWord.IsEmpty)
			{
				if (s.Kind == .Get)
					outKey.Append(" get");
				else if (s.Kind == .Set)
					outKey.Append(" set");
			}
			for (let p in s.Pins)
				if (!p.IsOutput && !p.Type.IsEmpty)
					outKey.AppendF(" {}", p.Type);
		}

		/// Splits "GetActorLocation" into "Get Actor Location" (what the search key and the label use).
		public static void Words(StringView name, String outText)
		{
			char8 prev = ' ';
			for (int i < name.Length)
			{
				let c = name[i];
				if (c == '_')
				{
					if (prev != ' ')
						outText.Append(' ');
					prev = ' ';
					continue;
				}
				bool boundary = c.IsUpper && prev != ' ' && (!prev.IsUpper || (i + 1 < name.Length && name[i + 1].IsLower));
				if (boundary)
					outText.Append(' ');
				outText.Append(c);
				prev = c;
			}
		}

		static uint64 CharMask(StringView s)
		{
			uint64 m = 0;
			for (let c in s.RawChars)
			{
				if (c >= 'a' && c <= 'z')
					m |= 1UL << (c - 'a');
				else if (c >= '0' && c <= '9')
					m |= 1UL << (26 + (c - '0'));
			}
			return m;
		}

		public int32 CategoryId(StringView path)
		{
			String p = scope .(path);
			p.Trim();
			if (mCategoryIds.TryGetValue(p, let id))
				return id;
			let s = new String(p);
			let n = (int32)Categories.Count;
			Categories.Add(s);
			mCategoryIds[s] = n;
			return n;
		}

		/// Copies the spec of an entry.
		public void GetSpec(int32 id, NodeSpec spec)
		{
			Refresh();
			if (id < 0 || id >= Specs.Count)
				return;
			spec.CopyFrom(Specs[id]);
		}

		/// The spec of an entry (owned by the catalog; valid until the next Refresh).
		public NodeSpec Spec(int32 id)
		{
			Refresh();
			return (id >= 0 && id < Specs.Count) ? Specs[id] : null;
		}

		public NodeEntryKind KindOf(int32 id) => Specs[id].Kind;

		// ------------------------------------------------------------------ search

		/// `next` only adds characters to `prev`.
		static bool Narrows(StringView prev, StringView next)
		{
			return !prev.IsEmpty && next.Length >= prev.Length && next.StartsWith(prev);
		}

		public void Search(StringView query, List<SearchHit> outHits, int maxResults, delegate bool(int32 id) filter = null, delegate float(int32 id) bonus = null)
		{
			Refresh();
			String q = scope .(query);
			q.Trim();
			q.ToLower();
			String rawName = scope .();
			if (q.Contains('_') && !q.Contains(' '))
			{
				rawName.Set(q);
				q.Replace('_', ' ');
				q.Trim();
			}
			List<StringView> words = scope .();
			for (let w in q.Split(' '))
				if (!w.IsEmpty)
					words.Add(w);
			uint64 qmask = CharMask(q);
			String phrase = scope .();
			for (let w in words)
				phrase.AppendF("{}{}", phrase.IsEmpty ? "" : " ", w);
			bool incremental = mLastMatchesValid && Narrows(mLastQuery, q);
			int reuse = 0;
			if (incremental && words.Count >= 1 && mLastWordCount >= 1)
			{
				if (words.Count == mLastWordCount && mLastWordCount > 1)
					reuse = 1;
				else if (words.Count == mLastWordCount + 1 && q.Length > mLastQuery.Length && mLastQuery.Length > 0 &&
					q[mLastQuery.Length] == ' ' && !mLastQuery.EndsWith(' '))
					reuse = 2;
				else if (words.Count == mLastWordCount + 1 && mLastQuery.EndsWith(' '))
					reuse = 2;
			}
			List<int32> candidates = incremental ? scope:: List<int32>(mLastMatches.GetEnumerator()) : null;
			List<float> prevFull = (reuse != 0) ? scope:: List<float>(mLastFull.GetEnumerator()) : null;
			List<float> prevPrefix = (reuse != 0) ? scope:: List<float>(mLastPrefix.GetEnumerator()) : null;
			mLastMatches.Clear();
			mLastFull.Clear();
			mLastPrefix.Clear();
			mLastMatchesValid = !words.IsEmpty;
			mLastWordCount = words.Count;
			mLastQuery.Set(q);
			LastScanned = 0;
			float worst = float.MinValue;
			int count = (candidates != null) ? candidates.Count : Specs.Count;
			for (int k < count)
			{
				int ci = (candidates != null) ? k : -1;
				int32 id = (candidates != null) ? candidates[k] : (int32)k;
				LastScanned++;
				if ((mMasks[id] & qmask) != qmask)
					continue;
				let key = mKeys[id];
				let spec = Specs[id];
				float score = 0;
				float prefixSum = 0;
				if (!words.IsEmpty)
				{
					let display = spec.DisplayName;
					if (reuse == 1 && ci >= 0)
						prefixSum = prevPrefix[ci];
					else if (reuse == 2 && ci >= 0)
						prefixSum = prevFull[ci];
					else
					{
						for (int wi < words.Count - 1)
						{
							let ws = WordScore(key, display, words[wi]);
							if (ws <= 0)
							{
								prefixSum = -1;
								break;
							}
							prefixSum += ws;
						}
						if (prefixSum < 0)
							continue;
					}
					let last = WordScore(key, display, words.Back);
					if (last <= 0)
						continue;
					score = prefixSum + last;
					if (mLastMatchesValid)
					{
						mLastPrefix.Add(prefixSum);
						mLastFull.Add(score);
					}
					if (words.Count > 1)
						score += PhraseBonus(key, display, words, phrase);
					if (!rawName.IsEmpty && key.Contains(rawName))
						score += 120;
				}
				if (mLastMatchesValid)
					mLastMatches.Add(id);
				if (filter != null && !filter(id))
					continue;
				if (bonus != null)
					score += bonus(id);
				score -= spec.DisplayName.Length * 0.05f;
				if (spec.IsAdvanced)
					score -= 20;
				if (outHits.Count >= maxResults && score <= worst)
					continue;
				SearchHit hit = .() { Id = id, Score = score };
				int lo = 0;
				int hi = outHits.Count;
				while (lo < hi)
				{
					int mid = (lo + hi) / 2;
					if (outHits[mid].Score >= score)
						lo = mid + 1;
					else
						hi = mid;
				}
				outHits.Insert(lo, hit);
				if (outHits.Count > maxResults)
					outHits.PopBack();
				if (outHits.Count >= maxResults)
					worst = outHits.Back.Score;
			}
		}

		/// Scores one lowercase key against the query words (0 = no match).
		public static float ScoreKey(StringView key, StringView display, List<StringView> words, StringView phraseIn = default)
		{
			float total = 0;
			for (let w in words)
			{
				let best = WordScore(key, display, w);
				if (best <= 0)
					return 0;
				total += best;
			}
			return total + PhraseBonus(key, display, words, phraseIn);
		}

		/// One query word against a lowercase key: name prefix 100, word start 60 (+5 inside the
		/// display name), substring 30, acronym 40, letters in order 5+; 0 = no match.
		public static float WordScore(StringView key, StringView display, StringView w)
		{
			float best = 0;
			int at = key.IndexOf(w);
			if (at == 0)
				best = 100;
			else if (at > 0)
			{
				int pos = at;
				bool wordStart = false;
				while (pos >= 0)
				{
					if (pos == 0 || key[pos - 1] == ' ' || key[pos - 1] == '.' || key[pos - 1] == '_' || key[pos - 1] == '<' || key[pos - 1] == ',' || key[pos - 1] == '(')
					{
						wordStart = true;
						break;
					}
					let next = key.Substring(pos + 1).IndexOf(w);
					if (next < 0)
						break;
					pos = pos + 1 + next;
				}
				best = wordStart ? 60 : 30;
				if (pos < display.Length)
					best += 5;
			}
			else if (IsAcronym(key, w))
				best = 40;
			else
			{
				int ki = 0;
				int matched = 0;
				int starts = 0;
				for (let c in w.RawChars)
				{
					while (ki < key.Length && key[ki] != c)
						ki++;
					if (ki >= key.Length)
						break;
					if (ki == 0 || key[ki - 1] == ' ')
						starts++;
					matched++;
					ki++;
				}
				if (matched < w.Length)
					return 0;
				best = 5 + starts * 4;
			}
			return best;
		}

		static float PhraseBonus(StringView key, StringView display, List<StringView> words, StringView phraseIn)
		{
			float total = 0;
			if (words.Count > 1)
			{
				StringView phrase = phraseIn;
				if (phrase.IsEmpty)
				{
					String built = scope:: .();
					for (let w in words)
					{
						if (!built.IsEmpty)
							built.Append(' ');
						built.Append(w);
					}
					phrase = built;
				}
				let at = key.IndexOf(phrase);
				if (at == 0)
					total += 80;
				else if (at > 0 && at < display.Length && key[at - 1] == ' ')
					total += 50;
			}
			return total;
		}

		/// The letters of `w` are the first letters of later and later words of the key.
		static bool IsAcronym(StringView key, StringView w)
		{
			int wi = 0;
			for (int i < key.Length)
			{
				if (wi >= w.Length)
					break;
				bool start = i == 0 || key[i - 1] == ' ';
				if (start && key[i] == w[wi])
					wi++;
			}
			return wi >= w.Length && w.Length >= 2;
		}

		// ------------------------------------------------------------------ context

		/// Relevance of an entry to a pin (0 = can't connect, 1 = generic/unchecked,
		/// 2 = implicit conversion, 3 = exact / receiver type).
		public int8 ContextRelevance(int32 id, PinContext ctx, StringView pinType)
		{
			if (ctx == .None)
				return 1;
			Refresh();
			if (mContextKind != ctx || mContextType != pinType)
			{
				mContextMemo.Clear();
				mContextKind = ctx;
				mContextType.Set(pinType);
			}
			int64 memoKey = ((int64)id << 2) | (int64)ctx;
			if (mContextMemo.TryGetValue(memoKey, let memo))
				return memo;
			let spec = Specs[id];
			let types = Types;
			int8 Check(StringView typeIn, bool from, bool stripArray = false)
			{
				var t = typeIn;
				if (stripArray && t.EndsWith("[]"))
					t.RemoveFromEnd(2);
				Conversion c = .Unchecked;
				if (types != null)
					c = from ? types.CanConvert(pinType, t, null) : types.CanConvert(t, pinType, null);
				switch (c)
				{
				case .Exact: return 3;
				case .Implicit: return 2;
				case .Unchecked: return (TypeRules.IsGenericParam(t) || TypeRules.IsGenericParam(pinType)) ? 1 : 0;
				case .Refused: return 0;
				}
			}
			int8 best = 0;
			if (ctx == .TakesValue)
			{
				if (!spec.IsStatic && spec.Kind != .Event && !spec.OwnerType.IsEmpty)
				{
					String pinCore = scope .();
					TypeRules.Normalize(pinType, pinCore);
					if (TypeRules.BaseName(pinCore) == spec.OwnerType || (types != null && types.IsSubtype(pinCore, spec.OwnerType)))
						best = 3;
				}
				if (best < 3)
				{
					if (spec.Kind == .Set)
						best = Math.Max(best, Check(spec.ReturnType, true));
					else
					{
						for (let p in spec.Pins)
						{
							if (p.IsOutput)
								continue;
							var r = Check(p.Type, true, p.Modifier.Contains("params"));
							if (r == 1 && !spec.IsGeneric)
								r = 0;
							best = Math.Max(best, r);
						}
					}
				}
			}
			else
			{
				if (spec.Kind == .Get || (!spec.ReturnType.IsEmpty && spec.ReturnType != "void"))
				{
					var r = Check(spec.ReturnType, false);
					if (r == 1 && !spec.IsGeneric)
						r = 0;
					best = r;
				}
				for (let p in spec.Pins)
				{
					if (!p.IsOutput)
						continue;
					var r = Check(p.Type, false);
					if (r == 1 && !spec.IsGeneric)
						r = 0;
					best = Math.Max(best, r);
				}
			}
			mContextMemo[memoKey] = best;
			return best;
		}

		// ------------------------------------------------------------------ tree

		/// The category tree over every entry (built on first use after a change).
		public CategoryNode Tree
		{
			get
			{
				Refresh();
				if (mTree == null)
				{
					mTree = new .();
					List<CategoryNode> byCat = scope .();
					for (let cat in Categories)
					{
						CategoryNode node = mTree;
						for (var part in cat.Split('|'))
						{
							part.Trim();
							if (part.IsEmpty)
								continue;
							node = node.Child(part);
						}
						byCat.Add(node);
					}
					for (int i < Specs.Count)
						byCat[mCategoryOf[i]].Entries.Add((int32)i);
					CountTotals(mTree);
				}
				return mTree;
			}
		}

		static int32 CountTotals(CategoryNode n)
		{
			int32 total = (int32)n.Entries.Count;
			for (let c in n.Children)
				total += CountTotals(c);
			n.Total = total;
			return total;
		}
	}
}
