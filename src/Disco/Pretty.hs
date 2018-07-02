{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE TypeFamilies              #-}
{-# LANGUAGE ViewPatterns              #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Disco.Pretty
-- Copyright   :  (c) 2016-2017 disco team (see LICENSE)
-- License     :  BSD-style (see LICENSE)
-- Maintainer  :  byorgey@gmail.com
--
-- Various pretty-printing facilities for disco.
--
-----------------------------------------------------------------------------

module Disco.Pretty where

import           System.IO                        (hFlush, stdout)

import           Control.Applicative              hiding (empty)
import           Control.Monad.Reader
import           Data.Char                        (isAlpha, toLower)
import qualified Data.Map                         as M
import           Data.Maybe                       (fromJust)
import           Data.Ratio

import qualified Text.PrettyPrint                 as PP
import           Unbound.Generics.LocallyNameless (Name, lunbind, unembed)

import           Disco.AST.Core
import           Disco.AST.Surface
import           Disco.Eval                       (Disco, IErr, Value (..), io,
                                                   iputStr, iputStrLn)
import           Disco.Interpret.Core             (whnfV)
import           Disco.Syntax.Operators
import           Disco.Types

--------------------------------------------------
-- Monadic pretty-printing

vcat :: Monad f => [f PP.Doc] -> f PP.Doc
vcat ds  = PP.vcat <$> sequence ds

hsep :: Monad f => [f PP.Doc] -> f PP.Doc
hsep ds  = PP.hsep <$> sequence ds

parens :: Functor f => f PP.Doc -> f PP.Doc
parens   = fmap PP.parens

brackets :: Functor f => f PP.Doc -> f PP.Doc
brackets = fmap PP.brackets

text :: Monad m => String -> m PP.Doc
text     = return . PP.text

integer :: Monad m => Integer -> m PP.Doc
integer  = return . PP.integer

nest :: Functor f => Int -> f PP.Doc -> f PP.Doc
nest n d = PP.nest n <$> d

empty :: Monad m => m PP.Doc
empty    = return PP.empty

(<+>) :: Applicative f => f PP.Doc -> f PP.Doc -> f PP.Doc
(<+>) = liftA2 (PP.<+>)

(<>) :: Applicative f => f PP.Doc -> f PP.Doc -> f PP.Doc
(<>)  = liftA2 (PP.<>)

($+$) :: Applicative f => f PP.Doc -> f PP.Doc -> f PP.Doc
($+$) = liftA2 (PP.$+$)

punctuate :: Monad f => f PP.Doc -> [f PP.Doc] -> f [f PP.Doc]
punctuate p ds = do
  p' <- p
  ds' <- sequence ds
  return . map return $ PP.punctuate p' ds'

--------------------------------------------------
-- Precedence and associativity

type Prec = Int

ugetPA :: UOp -> PA
ugetPA op = PA (uPrec op) In

getPA :: BOp -> PA
getPA op = PA (bPrec op) (assoc op)

data PA = PA Prec BFixity
  deriving (Show, Eq)

instance Ord PA where
  compare (PA p1 a1) (PA p2 a2) = compare p1 p2 `mappend` (if a1 == a2 then EQ else LT)

initPA :: PA
initPA = PA 0 InL

funPA :: PA
funPA = PA funPrec InL

arrPA :: PA
arrPA = PA 1 InR

type Doc = ReaderT PA (Disco IErr) PP.Doc

renderDoc :: Doc -> Disco IErr String
renderDoc = fmap PP.render . flip runReaderT initPA

--------------------------------------------------

prettyTy :: Type -> Doc
prettyTy (TyVar v)        = text (show v)
prettyTy TyVoid           = text "Void"
prettyTy TyUnit           = text "Unit"
prettyTy TyBool           = text "Bool"
prettyTy (TyArr ty1 ty2)  = mparens arrPA $
  prettyTy' 1 InL ty1 <+> text "→" <+> prettyTy' 1 InR ty2
prettyTy (TyPair ty1 ty2) = mparens (PA 7 InR) $
  prettyTy' 7 InL ty1 <+> text "×" <+> prettyTy' 7 InR ty2
prettyTy (TySum  ty1 ty2) = mparens (PA 6 InR) $
  prettyTy' 6 InL ty1 <+> text "+" <+> prettyTy' 6 InR ty2
prettyTy TyN              = text "ℕ"
prettyTy TyZ              = text "ℤ"
prettyTy TyQ              = text "ℚ"
prettyTy TyQP             = text "ℚ⁺"
prettyTy (TyFin n)        = text "ℤ" <> (integer n)
prettyTy (TyList ty)      = mparens (PA 9 InR) $
  text "List" <+> prettyTy' 9 InR ty

prettyTy' :: Prec -> BFixity -> Type -> Doc
prettyTy' p a t = local (const (PA p a)) (prettyTy t)

prettySigma :: Sigma -> Doc
prettySigma (Forall bnd) = lunbind bnd $
  \(tyvars, body) -> case tyvars of
                      [] -> prettyTy body
                      _  -> text "forany" <+> prettyTyVars tyvars <> text "." <+> prettyTy body
                      where prettyTyVars tyvars = hsep (map prettyName tyvars)
--------------------------------------------------

mparens :: PA -> Doc -> Doc
mparens pa doc = do
  parentPA <- ask
  (if (pa < parentPA) then parens else id) doc

prettyName :: (Show a) => Name a -> Doc
prettyName = text . show

prettyTerm :: Term -> Doc
prettyTerm (TVar x)      = prettyName x
prettyTerm (TParens t)   = prettyTerm t
prettyTerm TUnit         = text "()"
prettyTerm (TBool b)     = text (map toLower $ show b)
prettyTerm (TAbs bnd)    = mparens initPA $
  lunbind bnd $ \(args, body) ->
  hsep (map prettyArg args) <+> text "↦" <+> prettyTerm' 0 InL body
  where
    prettyArg (x, unembed -> mty) = case mty of
      Nothing -> prettyName x
      Just ty -> text "(" <> prettyName x <+> text ":" <+> prettyTy ty <> text ")"
prettyTerm (TApp t1 t2)  = mparens funPA $
  prettyTerm' funPrec InL t1 <+> prettyTerm' funPrec InR t2
prettyTerm (TTup ts)     = do
  ds <- punctuate (text ",") (map (prettyTerm' 0 InL) ts)
  parens (hsep ds)
prettyTerm (TList ts e)  = do
  ds <- punctuate (text ",") (map (prettyTerm' 0 InL) ts)
  let pe = case e of
             Nothing        -> []
             Just Forever   -> [text ".."]
             Just (Until t) -> [text "..", prettyTerm t]
  brackets (hsep (ds ++ pe))
prettyTerm (TListComp bqst) =
  lunbind bqst $ \(qs,t) ->
  brackets (hsep [prettyTerm' 0 InL t, text "|", prettyQuals qs])
prettyTerm (TInj side t) = mparens funPA $
  prettySide side <+> prettyTerm' funPrec InR t
prettyTerm (TNat n)      = integer n
prettyTerm (TUn Fact t)  = prettyTerm' (1 + funPrec) InL t <> text "!"
prettyTerm (TUn op t)    = mparens (ugetPA op) $
  prettyUOp op <> prettyTerm' (1 + funPrec) InR t
prettyTerm (TBin op t1 t2) = mparens (getPA op) $
  hsep
  [ prettyTerm' (bPrec op) InL t1
  , prettyBOp op
  , prettyTerm' (bPrec op) InR t2
  ]
prettyTerm (TChain t lks) = mparens (getPA Eq) . hsep $
    prettyTerm' (bPrec Eq) InL t
    : concatMap prettyLink lks
  where
    prettyLink (TLink op t2) =
      [ prettyBOp op
      , prettyTerm' (bPrec op) InR t2
      ]
prettyTerm (TLet bnd) = mparens initPA $
  lunbind bnd $ \(bs, t2) -> do
    ds <- punctuate (text ",") (map prettyBinding (fromTelescope bs))
    hsep
      [ text "let"
      , hsep ds
      , text "in"
      , prettyTerm' 0 InL t2
      ]
  where
    prettyBinding :: Binding -> Doc
    prettyBinding (Binding Nothing x (unembed -> t))
      = hsep [prettyName x, text "=", prettyTerm' 0 InL t]
    prettyBinding (Binding (Just (unembed -> ty)) x (unembed -> t))
      = hsep [prettyName x, text ":", prettySigma ty, text "=", prettyTerm' 0 InL t]

prettyTerm (TCase b)    = (text "{?" <+> prettyBranches b) $+$ text "?}"
  -- XXX FIX ME: what is the precedence of ascription?
prettyTerm (TAscr t ty) = parens (prettyTerm t <+> text ":" <+> prettySigma ty)
prettyTerm (TRat  r)    = text (prettyDecimal r)
prettyTerm (TTyOp op ty)  = mparens funPA $
    prettyTyOp op <+> prettyTy' funPrec InR ty

prettyTerm' :: Prec -> BFixity -> Term -> Doc
prettyTerm' p a t = local (const (PA p a)) (prettyTerm t)

prettySide :: Side -> Doc
prettySide L = text "left"
prettySide R = text "right"

prettyTyOp :: TyOp -> Doc
prettyTyOp Enumerate = text "enumerate"
prettyTyOp Count     = text "count"

prettyUOp :: UOp -> Doc
prettyUOp op =
  case M.lookup op uopMap of
    Just (OpInfo _ (syn:_) _) ->
      text $ syn ++ (if all isAlpha syn then " " else "")
    _ -> error $ "UOp " ++ show op ++ " not in uopMap!"

prettyBOp :: BOp -> Doc
prettyBOp op =
  case M.lookup op bopMap of
    Just (OpInfo _ (syn:_) _) -> text syn
    _ -> error $ "BOp " ++ show op ++ " not in bopMap!"

prettyBranches :: [Branch] -> Doc
prettyBranches []     = error "Empty branches are disallowed."
prettyBranches (b:bs) =
  prettyBranch False b
  $+$
  foldr ($+$) empty (map (prettyBranch True) bs)

prettyBranch :: Bool -> Branch -> Doc
prettyBranch com br = lunbind br $ \(gs,t) ->
  (if com then (text "," <+>) else id) (prettyTerm t <+> prettyGuards gs)

prettyGuards :: Telescope Guard -> Doc
prettyGuards TelEmpty                     = text "otherwise"
prettyGuards (fromTelescope -> gs)
  = foldr (\g r -> prettyGuard g <+> r) (text "") gs

prettyGuard :: Guard -> Doc
prettyGuard (GBool et)  = text "if" <+> (prettyTerm (unembed et))
prettyGuard (GPat et p) = text "when" <+> prettyTerm (unembed et) <+> text "is" <+> prettyPattern p

prettyQuals :: Telescope Qual -> Doc
prettyQuals (fromTelescope -> qs) = do
  ds <- punctuate (text ",") (map prettyQual qs)
  hsep ds

prettyQual :: Qual -> Doc
prettyQual (QBind x (unembed -> t))
  = hsep [prettyName x, text "in", prettyTerm' 0 InL t]
prettyQual (QGuard (unembed -> t))
  = prettyTerm' 0 InL t

prettyPattern :: Pattern -> Doc
prettyPattern (PVar x) = prettyName x
prettyPattern PWild = text "_"
prettyPattern PUnit = text "()"
prettyPattern (PBool b) = text $ map toLower $ show b
prettyPattern (PTup ts) = do
  ds <- punctuate (text ",") (map prettyPattern ts)
  parens (hsep ds)
prettyPattern (PInj s p) = prettySide s <+> prettyPattern p
prettyPattern (PNat n) = integer n
prettyPattern (PSucc p) = text "S" <+> prettyPattern p
prettyPattern (PCons {}) = error "prettyPattern PCons unimplemented"
prettyPattern (PList {}) = error "prettyPattern PCons unimplemented"

------------------------------------------------------------

-- prettyModule :: Module -> Doc
-- prettyModule = foldr ($+$) empty . map prettyDecl

prettyDecl :: Decl -> Doc
prettyDecl (DType x ty) = prettyName x <+> text ":" <+> prettySigma ty
prettyDecl (DDefn x bs) = vcat $ map prettyClause bs
  where
    prettyClause b
      = lunbind b $ \(ps, t) ->
        (prettyName x <+> (hsep $ map prettyPattern ps) <+> text "=" <+> prettyTerm t) $+$ text " "

prettyProperty :: Property -> Doc
prettyProperty prop =
  lunbind prop $ \(vars, t) ->
  case vars of
    [] -> prettyTerm t
    _  -> do
      dvars <- punctuate (text ",") (map prettyTyBind vars)
      text "∀" <+> hsep dvars <> text "." <+> prettyTerm t
  where
    prettyTyBind (x,ty) = hsep [prettyName x, text ":", prettyTy ty]


------------------------------------------------------------

------------------------------------------------------------
-- Pretty-printing values
------------------------------------------------------------

-- | Pretty-printing of values, with output interleaved lazily with
--   evaluation.  This version actually prints the values on the console, followed
--   by a newline.  For a more general version, see 'prettyValueWith'.
prettyValue :: Type -> Value -> Disco IErr ()
prettyValue ty v = do
  prettyValueWith (\s -> iputStr s >> io (hFlush stdout)) ty v
  iputStrLn ""

-- | Pretty-printing of values, with output interleaved lazily with
--   evaluation.  Takes a continuation that specifies how the output
--   should be processed (which will be called many times as the
--   output is produced incrementally).
prettyValueWith :: (String -> Disco IErr ()) -> Type -> Value -> Disco IErr ()
prettyValueWith k ty = whnfV >=> prettyWHNF k ty

-- | Pretty-print a value which is already guaranteed to be in weak
--   head normal form.
prettyWHNF :: (String -> Disco IErr ()) -> Type -> Value -> Disco IErr ()
prettyWHNF out TyUnit          (VCons 0 []) = out "()"
prettyWHNF out TyBool          (VCons i []) = out $ map toLower (show (toEnum i :: Bool))
prettyWHNF out (TyList ty)     v            = prettyList out ty v
prettyWHNF out ty@(TyPair _ _) v            = out "(" >> prettyTuple out ty v >> out ")"
prettyWHNF out (TySum ty1 ty2) (VCons i [v])
  = case i of
      0 -> out "left "  >> prettyValueWith out ty1 v
      1 -> out "right " >> prettyValueWith out ty2 v
      _ -> error "Impossible! Constructor for sum is neither 0 nor 1 in prettyWHNF"
prettyWHNF out _ (VNum d r)
  | denominator r == 1 = out $ show (numerator r)
  | otherwise          = case d of
      Fraction -> out $ show (numerator r) ++ "/" ++ show (denominator r)
      Decimal  -> out $ prettyDecimal r

prettyWHNF out _ (VFun _) = out "<function>"

prettyWHNF out _ (VClos _ _) = out "<function>"

prettyWHNF _ ty v = error $
  "Impossible! No matching case in prettyWHNF for " ++ show v ++ ": " ++ show ty


prettyList :: (String -> Disco IErr ()) -> Type -> Value -> Disco IErr ()
prettyList out ty v = out "[" >> go v
  where
    go (VCons 0 []) = out "]"
    go (VCons 1 [hd, tl]) = do
      prettyValueWith out ty hd
      tlWHNF <- whnfV tl
      case tlWHNF of
        VCons 1 _ -> out ", "
        _         -> return ()
      go tlWHNF

    go v' = error $ "Impossible! Value that's not a list in prettyList: " ++ show v'

prettyTuple :: (String -> Disco IErr ()) -> Type -> Value -> Disco IErr ()
prettyTuple out (TyPair ty1 ty2) (VCons 0 [v1, v2]) = do
  prettyValueWith out ty1 v1
  out ", "
  whnfV v2 >>= prettyTuple out ty2
prettyTuple out ty v = prettyValueWith out ty v

--------------------------------------------------
-- Pretty-printing decimals

-- | Pretty-print a rational number using its decimal expansion, in
--   the format @nnn.prefix[rep]...@, with any repeating digits enclosed
--   in square brackets.
prettyDecimal :: Rational -> String
prettyDecimal r = show n ++ "." ++ fractionalDigits
  where
    (n,d) = properFraction r :: (Integer, Rational)
    (prefix,rep) = digitalExpansion 10 (numerator d) (denominator d)
    fractionalDigits = concatMap show prefix ++ repetend
    repetend = case rep of
      []  -> ""
      [0] -> ""
      _   -> "[" ++ concatMap show rep ++ "]"

-- Given a list, find the indices of the list giving the first and
-- second occurrence of the first element to repeat, or Nothing if
-- there are no repeats.
findRep :: Ord a => [a] -> Maybe (Int,Int)
findRep = findRep' M.empty 0

findRep' :: Ord a => M.Map a Int -> Int -> [a] -> Maybe (Int,Int)
findRep' _ _ [] = Nothing
findRep' prevs ix (x:xs)
  | x `M.member` prevs = Just (prevs M.! x, ix)
  | otherwise          = findRep' (M.insert x ix prevs) (ix+1) xs

slice :: (Int,Int) -> [a] -> [a]
slice (s,f) = drop s . take f

-- | @digitalExpansion b n d@ takes the numerator and denominator of a
--   fraction n/d between 0 and 1, and returns two lists of digits
--   @(prefix, rep)@, such that the infinite base-b expansion of n/d is
--   0.@(prefix ++ cycle rep)@.  For example,
--
--   > digitalExpansion 10 1 4  = ([2,5],[0])
--   > digitalExpansion 10 1 7  = ([], [1,4,2,8,5,7])
--   > digitalExpansion 10 3 28 = ([1,0], [7,1,4,2,8,5])
--   > digitalExpansion 2  1 5  = ([], [0,0,1,1])
--
--   It works by performing the standard long division algorithm, and
--   looking for the first time that the remainder repeats.
digitalExpansion :: Integer -> Integer -> Integer -> ([Integer],[Integer])
digitalExpansion b n d = (prefix,rep)
  where
    longDivStep (_, r) = ((b*r) `divMod` d)
    res       = tail $ iterate longDivStep (0,n)
    digits    = map fst res
    lims      = fromJust $ findRep res
                -- fromJust is OK here: the remainders in the long
                -- division algorithm are limited to [0,d), so by the
                -- Pigeonhole Principle they must eventually repeat,
                -- so findRep is guaranteed to find a repeat.

    rep       = slice lims digits
    prefix    = take (fst lims) digits
