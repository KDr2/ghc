-- This rule has a type error on the LHS
module T24026b where

{-# RULES "f" forall (x :: Bool). f x = 0 #-}

f :: Int -> Int
f x = 0
