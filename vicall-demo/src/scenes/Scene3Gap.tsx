import React from 'react';
import {interpolate, spring, useCurrentFrame, useVideoConfig} from 'remotion';
import {SceneContainer} from '../components/SceneContainer';
import {colors, fonts} from '../theme';

export const Scene3Gap: React.FC<{durationInFrames?: number}> = ({durationInFrames}) => {
	const frame = useCurrentFrame();
	const {fps} = useVideoConfig();
	const progress = spring({
		fps,
		frame,
		config: {damping: 180, stiffness: 220},
		durationInFrames: 22,
	});

	return (
		<SceneContainer durationInFrames={durationInFrames}>
			<div
				style={{
					flex: 1,
					display: 'flex',
					flexDirection: 'column',
					alignItems: 'center',
					justifyContent: 'center',
					padding: '0 180px',
					gap: 26,
					opacity: progress,
					transform: `translateY(${interpolate(progress, [0, 1], [30, 0])}px)`,
					filter: `blur(${interpolate(progress, [0, 1], [8, 0])}px)`,
				}}
			>
				<div
					style={{
						fontFamily: fonts.headline,
						fontWeight: 800,
						fontSize: 84,
						lineHeight: 1.1,
						textAlign: 'center',
						color: colors.text,
					}}
				>
					Your <span style={{color: colors.accentSoft}}>voice channel</span> has{' '}
					<span style={{color: colors.danger}}>zero</span> protection.
				</div>
				<div
					style={{
						fontFamily: fonts.body,
						fontSize: 31,
						lineHeight: 1.35,
						textAlign: 'center',
						color: colors.muted,
						maxWidth: 1140,
					}}
				>
					Email is <span style={{color: colors.accentSoft}}>protected</span>. Endpoints are{' '}
					<span style={{color: colors.accentSoft}}>protected</span>. Voice calls are{' '}
					<span style={{color: colors.danger}}>not</span>.
				</div>
				<div
					style={{
						fontFamily: fonts.body,
						fontSize: 16,
						textAlign: 'center',
						color: colors.muted,
						opacity: 0.8,
					}}
				>
					*Source: AI Voice Cloning Fraud Statistics 2026 Report
				</div>
			</div>
		</SceneContainer>
	);
};
