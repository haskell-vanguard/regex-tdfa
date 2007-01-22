module Text.Regex.TDFA.TDFA(DFA(..),DT(..)
                           ,patternToDFA,nfaToDFA,dfaMap) where

import Control.Arrow((***))
import Data.Monoid
import Control.Monad.Reader
import Control.Monad.Writer
import Control.Monad.State
import Control.Monad.RWS
import Control.Monad.Instances
import Data.List
import Data.Maybe

import Data.Array.IArray
import Data.Set(Set)
import qualified Data.Set as Set
-- import Data.IntSet(IntSet)
import qualified Data.IntSet as ISet
import Data.Map(Map)
import qualified Data.Map as Map
import Data.IntMap(IntMap)
import qualified Data.IntMap as IMap

import Text.Regex.TDFA.TNFA
import Text.Regex.TDFA.Common
import Text.Regex.TDFA.CorePattern
import Text.Regex.TDFA.Pattern
import Text.Regex.TDFA.IntArrTrieSet(TrieSet)
import qualified Text.Regex.TDFA.IntArrTrieSet as Trie


import Text.Regex.Base(RegexOptions(defaultCompOpt))
import Text.Regex.TDFA.ReadRegex(parseRegex)

-- import Debug.Trace

debug :: (Show a) => a -> s -> s
debug _ s = s

{-
dlose :: DFA
dwin  = DFA { d_id = ISet.singleton 0
            , d_dt = Simple' { dt_win = IMap.singleton 0 (\j -> [(0,j)])
                             , dt_trans = Map.empty
                             , dt_other = Nothing } }
-}
dlose :: DFA
dlose = DFA { d_id = ISet.empty
            , d_dt = Simple'{ dt_win = IMap.empty
                            , dt_trans = Map.empty
                            , dt_other = Nothing } }

-- Specilized utility
ungroupBy :: (a->x) -> ([a]->y) -> [[a]] -> [(x,y)]
ungroupBy f g = map helper where
  helper [] = (error "empty group passed to ungroupBy",g [])
  helper x@(x1:_) = (f x1,g x)

askPre :: RunState Position
askPre = asks fst

askPost :: RunState Position
askPost = asks fst

getMap :: RunState (IntMap Position)
getMap = get

putMap :: IntMap Position -> RunState ()
putMap x = seq x (put x)

modifyMap :: (IntMap Position -> IntMap Position) -> RunState ()
modifyMap f = do
  m <- getMap
  putMap (f m)

resetTag :: Tag -> RunState ()
resetTag tag = modifyMap (IMap.delete tag)

setPreTag :: Tag -> RunState ()
setPreTag tag = do
  pos <- askPre
  modifyMap (IMap.insert tag pos)

setPostTag :: Tag -> RunState ()
setPostTag tag = do
  pos <- askPost
  let pos' = succ pos in seq pos' $ modifyMap (IMap.insert tag pos')

enterOrbit :: Tag -> RunState ()
enterOrbit tag = do
  pos <- askPre
  tell ["Entering Orbit "++show (tag,pos)]
  modifyMap (IMap.insert tag (negate tag))

leaveOrbit :: Tag -> RunState ()
leaveOrbit tag = do
  pos <- askPre
  tell ["Leaving Orbit "++show (tag,pos)]
  resetTag tag

nfaToDFA :: ((Index,Array Index QNFA),Array Tag OP,Array PatternIndex [GroupInfo])
         -> (DFA,Index,Array Tag OP,Array PatternIndex [GroupInfo])
nfaToDFA ((startIndex,aIndexQNFA),aTagOp,aGroupInfo) =
  let trie :: TrieSet DFA
      trie = Trie.fromSingles dlose mergeDFA (bounds aIndexQNFA) indexToDFA

      op = (aTagOp!)  -- Maximize or Minimize the given Tag
      indexToDFA = qnfaToDFA . (aIndexQNFA!)  -- used to seed the Trie
      indexesToDFA = Trie.lookupAsc trie  -- Lookup in cache

      makeWinner :: Index -> WinTags -> IntMap {- Index -} (RunState ())
      makeWinner i w | noWin w = IMap.empty
                     | otherwise = IMap.singleton i . makeUpdater . cleanWin $ w

      makeUpdater :: TagList -> RunState ()
      makeUpdater spec = specRunState
        where specRunState = sequence_ . map helper $ spec
              helper (tag,update) = case update of
                                       PreUpdate TagTask -> setPreTag tag
                                       PreUpdate ResetTask -> resetTag tag
                                       PreUpdate EnterOrbitTask -> enterOrbit tag
                                       PreUpdate LeaveOrbitTask -> leaveOrbit tag
                                       PostUpdate TagTask -> setPostTag tag
                                       _ -> error ("Weird command in makeUpdater: "++show (tag,update,spec))
{-
      makeUpdater :: [(Tag,TagUpdate)] -> Delta
      makeUpdater spec = sequence fspec -- Monad (Reader ((->) Tag))
        where fspec = do (tag,update) <- spec -- Monad []
                         return $ case update of
                                    PreTag   -> (\j->(tag,j))
                                    PostTag  -> (\j->(tag,succ j))
                                    ResetTag -> (\_->(tag,updateReset))
                                    EnterOrbit -> (\_ -> (tag,updateEnterOrbit))
                                    LeaveOrbit -> (\_ -> (tag,updateLeaveOrbit))
-}
      makeDFA i dt = debug ("\n>Making DFA "++show i++"<") $ DFA i dt

      qnfaToDFA :: QNFA -> DFA
      qnfaToDFA (QNFA {q_id = source,q_qt = qtIn}) = makeDFA (ISet.singleton source) (qtToDT qtIn)
        where
          f (dest,(dopa,spec)) = (dest,(source,(dopa,makeUpdater spec)))

          qtToDT :: QT -> DT
          qtToDT qt = case qt of
                         Simple {qt_win=w, qt_trans=t, qt_other=o} ->
                           Simple' { dt_win = makeWinner source w
                                   , dt_trans = fmap qtransToDFA t
                                   , dt_other = if IMap.null o then Nothing else Just (qtransToDFA o)}
                         Testing {qt_test=wt, qt_dopas=dopas, qt_a=a, qt_b=b} ->
                           Testing' { dt_test = wt
                                    , dt_dopas = dopas
                                    , dt_a = qtToDT a
                                    , dt_b = qtToDT b }
            where
              qtransToDFA :: QTrans -> (DFA,DTrans)
              qtransToDFA qtrans = (indexesToDFA (IMap.keys dtrans),dtrans)
                where
                  dtrans = qtransToDTrans qtrans
                  qtransToDTrans :: QTrans -> DTrans
                  qtransToDTrans = IMap.fromAscList . ungroupBy fst (IMap.fromList . (map snd))
                                   . groupBy ((==) `on` fst) . sortBy (compare `on` fst)
                                   . map f . pickQTrans op

      mergeDFA :: DFA -> DFA -> DFA
      mergeDFA d1 d2 = makeDFA i dt
        where
          i = d_id d1 `mappend` d_id d2
          dt = d_dt d1 `mergeDT` d_dt d2
          mergeDT :: DT -> DT -> DT
          mergeDT (Simple' w1 t1 o1) (Simple' w2 t2 o2) = Simple' w t o
            where
              w = w1 `mappend` w2
              t = fuseDTrans t1 o1 t2 o2
              o = case (o1,o2) of (Just o1', Just o2') -> Just (mergeDTrans o1' o2')
                                  _ -> o1 `mplus` o2
          mergeDT dt1@(Testing' wt1 dopas1 a1 b1) dt2@(Testing' wt2 dopas2 a2 b2) =
            case compare wt1 wt2 of
              LT -> nestDT dt1 dt2
              EQ -> Testing' { dt_test = wt1
                             , dt_dopas = dopas1 `mappend` dopas2
                             , dt_a = mergeDT a1 a2
                             , dt_b = mergeDT b1 b2 }
              GT -> nestDT dt2 dt1
          mergeDT dt1@(Testing' {}) dt2 = nestDT dt1 dt2
          mergeDT dt1 dt2@(Testing' {}) = nestDT dt2 dt1
          nestDT dt1@(Testing' {dt_a=a,dt_b=b}) dt2 = dt1 { dt_a = mergeDT a dt2, dt_b = mergeDT b dt2 }
          nestDT _ _ = error "nestDT called on Simple -- cannot happen"

      mergeDTrans :: (DFA,DTrans) -> (DFA,DTrans) -> (DFA,DTrans)
      mergeDTrans (_,dt1) (_,dt2) = (indexesToDFA (IMap.keys dtrans),dtrans)
        where dtrans = IMap.unionWith IMap.union dt1 dt2

      fuseDTrans :: Map Char (DFA,DTrans) -> Maybe (DFA,DTrans)
                 -> Map Char (DFA,DTrans) -> Maybe (DFA,DTrans)
                 -> Map Char (DFA,DTrans)
      fuseDTrans t1 o1 t2 o2 = Map.fromDistinctAscList (fuse l1 l2)
        where
          l1 = Map.toAscList t1
          l2 = Map.toAscList t2
          merge_o1 = case o1 of Nothing -> id
                                Just o1' -> mergeDTrans o1'
          merge_o2 = case o2 of Nothing -> id
                                Just o2' -> mergeDTrans o2'
          fuse [] y = if isJust o1 then mapSnd merge_o1 y else y
          fuse x [] = if isJust o2 then mapSnd merge_o2 x else x
          fuse x@((xc,xa):xs) y@((yc,ya):ys) = 
            case compare xc yc of
              LT -> (xc,merge_o2 xa) : fuse xs y
              EQ -> (xc,mergeDTrans xa ya) : fuse xs ys
              GT -> (yc,merge_o1 ya) : fuse x ys

      dfa = indexesToDFA [startIndex]
      msg = unlines [ show aTagOp
                    , show aGroupInfo
                    ]
  in debug msg $ (dfa,startIndex,aTagOp,aGroupInfo)

patternToDFA :: CompOption -> (Pattern,(PatternIndex, Int)) -> (DFA,Index,Array Tag OP,Array PatternIndex [GroupInfo])
patternToDFA compOpt pattern = nfaToDFA (patternToNFA compOpt pattern)

dfaMap :: DFA -> Map SetIndex DFA
dfaMap = seen (Map.empty) where
  seen old d@(DFA {d_id=i,d_dt=dt}) =
    if i `Map.member` old
      then old
      else let new = Map.insert i d old
           in foldl' seen new (flattenDT dt)

flattenDT :: DT -> [DFA]
flattenDT (Simple' {dt_trans=mt,dt_other=mo}) = map fst . maybe id (:) mo . Map.elems $ mt
flattenDT (Testing' {dt_a=a,dt_b=b}) = flattenDT a ++ flattenDT b

{-
-- trebug

Prelude Text.Regex.TRE Text.Regex.Base> let r=makeRegex  "((a)|(b*)|c(c*))*" :: Regex in match r "acbbacbb" :: MatchArray
array (0,4) [(0,(0,8)),(1,(6,2)),(2,(-1,0)),(3,(6,2)),(4,(6,2))]

Prelude Text.Regex.TRE Text.Regex.Base Text.Regex.Posix> let r=makeRegex  "(b*|c(c*))*" :: Text.Regex.TRE.Regex in match r "cbb" :: MatchArray
array (0,2) [(0,(0,3)),(1,(1,2)),(2,(1,2))]

The above is a bug.  the (c*) group should not match "bb".

-}

{-
      -- When a group is started we must clear its stop tag

      reseter :: [Tag] -> ([(Tag,Position)]->[(Tag,Position)])
      reseter tags = id -- foldr (\c->(((c,-1):).)) id tags'
        where tags' = (concatMap (ar!) tags) \\ tags

      ar :: Array Tag [Tag]
      ar = accumArray (++) [] (bounds aTagOp) (map reset (elems aGroupInfo))
        where reset (GroupInfo this parent start stop) = (start, [stop])

-}

fillMap :: Tag -> IntMap Position
fillMap tag = IMap.fromDistinctAscList [(t,-1) | t <- [0..tag] ]

diffMap :: IntMap Position -> IntMap Position -> [(Index,Position)]
diffMap old new = IMap.toList (IMap.differenceWith (\a b -> if a==b then Nothing else Just b) old new)

examineDFA :: (DFA,Index,Array Tag OP,Array PatternIndex [GroupInfo]) -> String
examineDFA (dfa,_,aTags,_) = unlines $ map (examineDFA' (snd . bounds $ aTags)) (Map.elems $ dfaMap dfa)

examineDFA' :: Tag -> DFA -> String
examineDFA' maxTag = showDFA (fillMap maxTag)

{-
instance Show DFA where
  show (DFA {d_id=i,d_dt=dt}) = "DFA {d_id = "++show (ISet.toList i)
                            ++"\n    ,d_dt = "++ show dt
                            ++"\n}"
-}
-- instance Show DT where show = showDT

showDFA :: IntMap Position -> DFA -> String
showDFA m (DFA {d_id=i,d_dt=dt}) = "DFA {d_id = "++show (ISet.toList i)
                               ++"\n    ,d_dt = "++ showDT m dt
                               ++"\n}"

showDT :: IntMap Position -> DT -> String
showDT m (Simple' w t o) = "Simple' { dt_win = " ++ (show . map (\(i,rs) -> (i,seeRS rs)) . IMap.assocs $ w)
                      ++ "\n        , dt_trans = " ++ (unlines . map show . mapSnd (ISet.toList . d_id *** seeDTrans) . Map.assocs $ t)
                      ++ "\n        , dt_other = " ++ maybe "None" (\o' -> (\ (a,b) -> "("++a++" , "++b++")" )
                                                                           . ( (show . ISet.toList . d_id) *** 
                                                                               (unlines . map show . seeDTrans) ) 
                                                                           $ o')
                                                                 o
                      ++ "\n        }"
  where seeDTrans :: DTrans -> DTrans'
        seeDTrans dtrans = 
          let x :: [(Index,IntMap (DoPa,RunState ()))]
              x = IMap.assocs dtrans
              y :: IntMap (DoPa,RunState ()) -> [(Index,(DoPa,([(Tag,Position)],[String])))]
              y z = mapSnd (\(dopa,rs) -> (dopa,seeRS rs))
                    . IMap.assocs $ z
          in mapSnd y x
        seeRS :: RunState () -> ([(Tag,Position)],[String])
        seeRS rs = let (s,w) = execRWS rs (0,0) m
                   in (diffMap m s,w)

showDT m (Testing' wt d a b) = "Testing' { dt_test = " ++ show wt
                          ++ "\n         , dt_dopas = " ++ show d
                          ++ "\n         , dt_a = " ++ indent a
                          ++ "\n         , dt_b = " ++ indent b
                          ++ "\n         }"
 where indent = init . unlines . (\(h:t) -> h : (map (spaces ++) t)) . lines . showDT m
       spaces = replicate 10 ' '

toDFA = nfaToDFA . toNFA
-- display_DFA = mapM_ print . Map.elems . dfaMap . (\(x,_,_,_) -> x) . toDFA 
