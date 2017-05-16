{-# LANGUAGE MultiParamTypeClasses,
             TemplateHaskell,
             FlexibleInstances,
             UndecidableInstances,
             ViewPatterns #-}

import Prelude hiding (pi)
import Unbound.LocallyNameless
import Unbound.LocallyNameless.Ops (unsafeUnbind)
--import Control.Monad.Trans.Maybe
--import Control.Applicative
import Control.Monad.Except
import Control.Arrow

data Term = Type
          | Pi (Bind (Name Term, Embed Term) Term)
          | Var (Name Term) -- name indexed by what they refer to
          | App Term Term
          | Lambda (Bind (Name Term, Embed Term) Term)
type Type = Term
            
$(derive [''Term]) -- derivices boilerplate instances

instance Alpha Term

instance Subst Term Term where
    isvar (Var v) = Just (SubstName v)
    isvar _            = Nothing
 
-- Indexing

-- TODO: This might be a good idea if you want to support good error messages.
--       I'm not sure how I ought to do this with bindings though.
--       Also, it'd be best if the mechanism worked equally well for a tree with
--       line numbers, etc.

instance Show Term where
  show = runLFreshM . show'
      where show' :: LFresh m => Term -> m String
            show' Type = return "Type"
            show' (Pi term) = lunbind term $ \((varName, unembed -> varType), body) -> do
                varTypeString <- show' varType
                bodyString <- show' body
                if containsFree varName body
                  then return $ "(" ++ name2String varName ++ ":" ++ varTypeString ++ ") -> " ++ bodyString
                  else return $ varTypeString ++ " -> " ++ bodyString
            show' (Var name) = return $ name2String name
            show' (App func arg) = do
                funcString <- show' func
                argString <- show' arg
                return $ "(" ++ funcString ++ ") (" ++ argString ++ ")" -- FIXME: unnecessary parens
            show' (Lambda term) = lunbind term $ \((varName, unembed -> varType), body) -> do
                varTypeString <- show' varType
                bodyString <- show' body
                return $ "λ" ++ name2String varName ++ ":" ++ varTypeString ++ "." ++ bodyString

            containsFree :: Name Term -> Term -> Bool
            containsFree name term = name `elem` (fv term :: [Name Term])

data IndexStep = AppFunc | AppArg | BindingType | BindingBody
  deriving Show
type Index =  [IndexStep]

unsafeIndex :: Term -> Index -> Term
unsafeIndex term [] = term
unsafeIndex (App func _)  (AppFunc:index)     = unsafeIndex func index
unsafeIndex (App _ arg)   (AppArg:index)      = unsafeIndex arg index
unsafeIndex (Pi term)     (BindingType:index) = let ((_, unembed -> varType), _) = unsafeUnbind term
                                                in unsafeIndex varType index
unsafeIndex (Pi term)     (BindingBody:index) = let ((_, _), body) = unsafeUnbind term
                                                in unsafeIndex body index
unsafeIndex (Lambda term) (BindingType:index) = let ((_, unembed -> varType), _) = unsafeUnbind term
                                                in unsafeIndex varType index
unsafeIndex (Lambda term) (BindingBody:index) = let ((_, _), body) = unsafeUnbind term
                                                in unsafeIndex body index
unsafeIndex term (step:_) = error $ "index step " ++ show step ++ " not in " ++ show term
    

-- Helpers
        
lambda :: String -> Type -> Term -> Term
lambda name typeAnnotation result = Lambda $ bind boundName result
    where boundName = ((string2Name name), embed typeAnnotation)

pi :: String -> Type -> Term -> Term
pi name typeAnnotation result = Pi $ bind boundName result
    where boundName = ((string2Name name), embed typeAnnotation)

var :: String -> Term
var = Var . string2Name

-- type checking
-- note: a mutually recursive design would be better in future

type Context = [(Name Term, Type)]

data TypeErrorReason = VariableNotInScope
                     | ExpectedFunction
                     | ExpectedTypeButFound Type Type
    deriving Show

data TypeError = TypeError {
  index :: Index,
  reason :: TypeErrorReason
} deriving Show

prettyError :: Term -> TypeError -> String
prettyError term (TypeError index (ExpectedTypeButFound expectedType foundType)) = 
    "Expected `" ++ show expectedType ++ "` but found `" ++ show foundType ++ "` while checking `" ++ show (unsafeIndex term (tail index)) ++ "`"
-- FIXME: Implement rest

elseThrowError :: Maybe a -> TypeError -> Except TypeError a
elseThrowError (Just x) _     = return x
elseThrowError Nothing  error = throwError error

check :: Index -> Context -> Type -> Term -> FreshMT (Except TypeError) ()
check index context expectedType term = do 
    foundType <- infer index context term
    if expectedType `aeq` foundType -- TODO: definitional eq
        then return ()
        else throwError $ TypeError index $ ExpectedTypeButFound expectedType foundType

-- Determine the type of a term
-- FIXME: Can we hide context in a monad?
-- FIXME: Can we report ALL errors instead of just the first?
infer :: Index -> Context -> Term -> FreshMT (Except TypeError) Type

-- Types have type "type".
-- This makes our language inconsistent as a logic
-- See: Girard's paradox
-- TODO: Use universes to make logic consistent.
infer _ _ Type = return Type

-- Check the type of a variable using the context.
-- TODO: Give a more informative error message.
infer index context (Var name) = lift $ 
    lookup name context `elseThrowError` TypeError index VariableNotInScope

infer index context (Lambda term) = do
    ((binding, unembed -> argType), body) <- unbind term
    check (BindingType:index) context Type argType
    bodyType <- infer (BindingBody:index) ((binding, argType):context) body
    return $ Pi (bind (binding, embed argType) bodyType)

infer index context (Pi term) = do
    ((binding, unembed -> argType), body) <- unbind term
    check (BindingType:index) context Type argType
    check (BindingBody:index) ((binding, argType):context) Type body
    return Type

infer index context (App func arg) = do
    expectedFuncType <- infer (AppFunc:index) context func
    case expectedFuncType of
        Pi funcType -> do
            ((binding, unembed -> expectedArgType), body) <- unbind funcType
            check (AppArg:index) context expectedArgType arg
            return $ subst binding arg body
        _ -> throwError $ TypeError index ExpectedFunction -- TODO: args?

runInfer :: Term -> Except TypeError Type
runInfer term = runFreshMT (infer [] [] term)

prettyRunInfer :: Term -> Either String Type
prettyRunInfer term = left (prettyError term) $ runExcept (runInfer term)

---- Small-step evaluation
--
--step :: Term -> MaybeT FreshM Term
--step Unit = mzero
--step (BoolLiteral _) = mzero
--step (Variable _) = mzero
--step (Lambda _) = mzero
--step (Application (Lambda abstraction) rightTerm) = do
--        ((name, _typeAnnotation), leftTerm) <- unbind abstraction
--        return $ subst name rightTerm leftTerm
--step (Application leftTerm rightTerm) = 
--        let reduceLeft = do leftTerm' <- step leftTerm
--                            return $ Application leftTerm' rightTerm in
--        let reduceRight = do rightTerm' <- step rightTerm
--                             return $ Application leftTerm rightTerm' in
--        reduceLeft <|> reduceRight
--
--reduce :: Term -> FreshM Term
--reduce term = do
--        result <- runMaybeT (step term)
--        case result of
--            Just term' -> reduce term'
--            Nothing -> return term
--
--eval :: Term -> Term
--eval term = runFreshM (reduce term)
--

---- Example

id' = lambda "t" Type $ 
          lambda "x" (var "t") $ 
              var "x"

bool' = pi "x" Type $
            pi "_" (var "x") $
                pi "_" (var "x") $
                    var "x"

true' = lambda "x" Type $
            lambda "y" (var "x") $
                lambda "z" (var "x") $
                    var "y"


--
---- BoolType
--program = (Application
--              (Application
--                  (lambda "x" BoolType $
--                      lambda "y" UnitType $
--                          var "x")
--                  (BoolLiteral False))
--              Unit)
--